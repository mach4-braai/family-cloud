<?php
// Overlay applied on top of the auto-generated config.php.
// The Nextcloud Docker entrypoint reads OBJECTSTORE_S3_* env vars and writes
// the `objectstore` block into the main config.php. The settings here are
// the ones the entrypoint does NOT cover.

$CONFIG = [
    // Known Nextcloud+S3 deadlock. See PLAN.md §7.4 gotcha #2.
    'filelocking.enabled' => false,

    // Files >80MB buffer through /tmp before S3 upload. The volume has more
    // headroom than the 40GB root disk on CX22. Sibling dir to the Postgres
    // data dir on the same Cloud Volume (see scripts/cloud-init.yaml.tpl).
    'upload_tmp_dir' => '/mnt/data/nextcloud-tmp',

    'default_phone_region' => 'DE',

    'maintenance_window_start' => 1,

    'loglevel' => 2,
    'log_type' => 'file',

    'trashbin_retention_obligation' => 'auto, 30',
    'versions_retention_obligation' => 'auto, 90',
];
