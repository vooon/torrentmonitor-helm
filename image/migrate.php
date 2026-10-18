<?php
// torrentmonitor-helm: database migrator, run before the app (init container /
// Helm hook): php /app/migrate.php
//
// Upstream keeps the database version in version.txt next to the code and
// updates both by downloading code at runtime (disabled in this image). Here
// the database records its own version in tm_schema_version, and the SQL for
// each upstream version comes from the update.xml committed to this repo
// (migrations/update.xml, reviewed like code) plus our own per-version files
// (migrations/<db type>/<version>.sql) where upstream has no SQL for a type.
//
//   empty database      load upstream db_schema/<type>.sql, stamp the image
//                       version
//   tm_schema_version   apply every update.xml step newer than it, up to the
//                       image version, oldest first; one transaction per step
//   upstream tables but no tm_schema_version
//                       refuse, unless TM_DB_BASELINE_VERSION says which
//                       version the database is at (adopting an existing
//                       install)
//   database newer than the image
//                       refuse (no downgrades)

error_reporting(E_ALL);
require '/app/config.php';

const APP = '/app';
const MIGRATIONS = '/usr/share/torrentmonitor/migrations';

function out($msg) { fwrite(STDOUT, '[migrate] '.$msg."\n"); }
function fail($msg) { fwrite(STDERR, '[migrate] ERROR: '.$msg."\n"); exit(1); }

$type = Config::read('db.type');
$version = json_decode(file_get_contents(APP.'/version.txt'));
if ( ! isset($version->system))
    fail('cannot read '.APP.'/version.txt');
$imageVersion = strval($version->system);

try
{
    if ($type == 'pgsql')
    {
        $pdo = new PDO('pgsql:host='.Config::read('db.host').';port='.Config::read('db.port').';dbname='.Config::read('db.basename'),
            Config::read('db.user'), Config::read('db.password'));
    }
    else
    {
        $pdo = new PDO('sqlite:'.Config::read('db.basename'));
    }
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
}
catch (PDOException $e)
{
    fail('cannot connect: '.$e->getMessage());
}

// One migrator at a time (a rollout and a manual run could overlap).
if ($type == 'pgsql')
    $pdo->query("SELECT pg_advisory_lock(hashtext('torrentmonitor-migrate'))");

function tableExists(PDO $pdo, $type, $table)
{
    if ($type == 'pgsql')
        $stmt = $pdo->prepare("SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?");
    else
        $stmt = $pdo->prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?");
    $stmt->execute(array($table));
    return (bool) $stmt->fetchColumn();
}

function setVersion(PDO $pdo, $v)
{
    $pdo->exec('DELETE FROM tm_schema_version');
    $stmt = $pdo->prepare('INSERT INTO tm_schema_version (version) VALUES (?)');
    $stmt->execute(array($v));
}

// Upstream's schemas insert rows with explicit ids, behind the sequences'
// backs (e.g. settings 42-44 while auto_id_settings starts at 42), so the
// next INSERT without an id would collide. Move every sequence used as a
// column default past the column's maximum.
function fixSequences(PDO $pdo, $type)
{
    if ($type != 'pgsql')
        return;
    $rows = $pdo->query("SELECT table_name, column_name, column_default FROM information_schema.columns
        WHERE table_schema = current_schema() AND column_default LIKE 'nextval(%'")->fetchAll(PDO::FETCH_ASSOC);
    foreach ($rows as $r)
    {
        if ( ! preg_match("/nextval\\('([^']+)'/", $r['column_default'], $m))
            continue;
        $seq = $m[1];
        $max = $pdo->query('SELECT COALESCE(MAX("'.$r['column_name'].'"), 0) FROM "'.$r['table_name'].'"')->fetchColumn();
        if ($max > 0)
            $pdo->query("SELECT setval('".$seq."', ".(int) $max.")");
    }
}

function createVersionTable(PDO $pdo)
{
    $pdo->exec('CREATE TABLE tm_schema_version (version VARCHAR(32) NOT NULL)');
}

// --- fresh database --------------------------------------------------------
if ( ! tableExists($pdo, $type, 'tm_schema_version') && ! tableExists($pdo, $type, 'settings'))
{
    $schema = APP.'/db_schema/'.($type == 'pgsql' ? 'postgresql' : 'sqlite').'.sql';
    out('empty database: loading '.$schema.' ('.$imageVersion.')');
    $pdo->beginTransaction();
    $pdo->exec(file_get_contents($schema));
    createVersionTable($pdo);
    setVersion($pdo, $imageVersion);
    $pdo->commit();
    fixSequences($pdo, $type);
    out('done: '.$imageVersion);
    exit(0);
}

// --- adopt an existing install --------------------------------------------
if ( ! tableExists($pdo, $type, 'tm_schema_version'))
{
    $baseline = getenv('TM_DB_BASELINE_VERSION');
    if ($baseline === FALSE || $baseline === '')
        fail('database has TorrentMonitor tables but no tm_schema_version; set TM_DB_BASELINE_VERSION to the version it is at');
    out('adopting existing database at '.$baseline);
    createVersionTable($pdo);
    setVersion($pdo, $baseline);
}

$current = strval($pdo->query('SELECT version FROM tm_schema_version')->fetchColumn());
if (version_compare($current, $imageVersion, '>'))
    fail('database is at '.$current.', newer than this image ('.$imageVersion.')');
if (version_compare($current, $imageVersion, '=='))
{
    out('up to date: '.$current);
    exit(0);
}

// --- upgrade ---------------------------------------------------------------
$xml = simplexml_load_file(MIGRATIONS.'/update.xml');
if ($xml === FALSE)
    fail('cannot read '.MIGRATIONS.'/update.xml');

$steps = array();
foreach ($xml->update as $u)
{
    $v = strval($u->version);
    if (version_compare($v, $current, '>') && version_compare($v, $imageVersion, '<='))
        $steps[$v] = $u;
}
uksort($steps, 'version_compare');

// Before any step: the database may come with lagging sequences too (an
// adopted install, or an old upstream schema), and steps insert rows.
fixSequences($pdo, $type);

foreach ($steps as $v => $u)
{
    $queries = array();
    foreach (array($type, 'queryes') as $section)
        if (isset($u->$section->query))
            foreach ($u->$section->query as $q)
                $queries[] = trim(strval($q));
    $override = MIGRATIONS.'/'.$type.'/'.$v.'.sql';
    if (is_file($override))
        $queries[] = file_get_contents($override);

    out($v.': '.count($queries).' statement(s)');
    $pdo->beginTransaction();
    try
    {
        foreach ($queries as $q)
            if ($q !== '')
                $pdo->exec($q);
        setVersion($pdo, $v);
        $pdo->commit();
        fixSequences($pdo, $type);
    }
    catch (PDOException $e)
    {
        $pdo->rollBack();
        fail($v.': '.$e->getMessage());
    }
}

// Versions without an update.xml entry (or with no SQL) still move the stamp.
setVersion($pdo, $imageVersion);
fixSequences($pdo, $type);
out('done: '.$current.' -> '.$imageVersion);
