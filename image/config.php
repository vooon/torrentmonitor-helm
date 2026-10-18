<?php
// torrentmonitor-helm: replaces upstream's config.php. Everything comes from
// the environment; nothing is written to disk.
//
//   TM_DB_TYPE         pgsql (default) | sqlite
//   TM_DB_HOST, TM_DB_PORT (5432), TM_DB_NAME, TM_DB_USER, TM_DB_PASSWORD
//                      pgsql
//   TM_DB_PATH         sqlite: absolute path of the database file
//   TM_ENCRYPTION_KEY  64 hex characters (32 bytes); encrypts the stored
//                      tracker and client passwords. Required: upstream would
//                      silently store them in plain text without it.
//   TM_CONFIG_XML      extended settings file (default: the image's
//                      /etc/torrentmonitor/config.xml), read-only
//   TM_CURL_CONCURRENCY optional

include_once dirname(__FILE__).'/class/Config.class.php';

function tm_env($name, $default = NULL)
{
    $v = getenv($name);
    return ($v === FALSE || $v === '') ? $default : $v;
}

function tm_fail($msg)
{
    error_log('torrentmonitor config: '.$msg);
    if (php_sapi_name() !== 'cli')
    {
        http_response_code(500);
        echo 'Configuration error: '.$msg."\n";
    }
    else
        fwrite(STDERR, 'Configuration error: '.$msg."\n");
    // exit("...") would exit 0 and let an init container pass.
    exit(1);
}

Config::extended(tm_env('TM_CONFIG_XML', '/etc/torrentmonitor/config.xml'));

$key = tm_env('TM_ENCRYPTION_KEY');
if ($key === NULL || ! preg_match('/^[0-9a-fA-F]{64}$/', $key))
    tm_fail('TM_ENCRYPTION_KEY must be 64 hex characters');
Config::write('encryption.key', $key);

$type = tm_env('TM_DB_TYPE', 'pgsql');
Config::write('db.type', $type);
switch ($type)
{
    case 'pgsql':
        foreach (array('TM_DB_HOST', 'TM_DB_NAME', 'TM_DB_USER', 'TM_DB_PASSWORD') as $v)
            if (tm_env($v) === NULL)
                tm_fail($v.' is required for pgsql');
        Config::write('db.host', tm_env('TM_DB_HOST'));
        Config::write('db.port', tm_env('TM_DB_PORT', '5432'));
        Config::write('db.basename', tm_env('TM_DB_NAME'));
        Config::write('db.user', tm_env('TM_DB_USER'));
        Config::write('db.password', tm_env('TM_DB_PASSWORD'));
        break;
    case 'sqlite':
        if (tm_env('TM_DB_PATH') === NULL)
            tm_fail('TM_DB_PATH is required for sqlite');
        Config::write('db.basename', tm_env('TM_DB_PATH'));
        break;
    default:
        tm_fail('TM_DB_TYPE must be pgsql or sqlite');
}

if (tm_env('TM_CURL_CONCURRENCY') !== NULL)
    Config::write('curl.concurrency', (int) tm_env('TM_CURL_CONCURRENCY'));
// For POST /api/run (spawns engine.php).
Config::write('php.cli', '/usr/local/bin/php');
?>
