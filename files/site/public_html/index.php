<?php
// The whole site enters here.
//
// This folder is nginx's document root and holds only what the browser is
// allowed to ask for: this file, the stylesheet and the script. Everything
// else — the application, the queries, the database password — lives one
// directory up, where no URL can reach it.

declare(strict_types=1);

require dirname(__DIR__) . '/app/bootstrap.php';
require APP_DIR . '/routes.php';

dispatch();
