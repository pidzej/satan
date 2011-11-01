-- Satan database schema
-- Rootnode http://rootnode.net
--
-- Copyright (C) 2009-2011 Marcin Hlybin
-- All rights reserved.

CREATE TABLE `backup_files` (
  `id` mediumint(8) unsigned NOT NULL,
  `fid` int(10) unsigned NOT NULL,
  `filename` varchar(256) NOT NULL,
  `type` enum('file','directory','mysql','pgsql') DEFAULT NULL,
  `server` char(14) NOT NULL,
  `include` enum('+','-') DEFAULT NULL,
  PRIMARY KEY (`fid`),
  KEY `id_idx` (`id`),
  CONSTRAINT `backup_files_ibfk_1` FOREIGN KEY (`id`) REFERENCES `backup_jobs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `backup_jobs` (
  `id` mediumint(8) unsigned NOT NULL,
  `uid` smallint(5) unsigned NOT NULL,
  `name` char(14) NOT NULL,
  `type` enum('home','www','db') NOT NULL,
  `size` char(10) DEFAULT NULL,
  `schedule` char(8) DEFAULT '3:0:0',
  `laststatus` varchar(128) DEFAULT NULL,
  `nextstatus` char(14) DEFAULT NULL,
  `lastbackup` datetime DEFAULT NULL,
  `nextbackup` datetime DEFAULT NULL,
  `active` tinyint(4) DEFAULT '1',
  PRIMARY KEY (`id`,`uid`),
  UNIQUE KEY `id` (`id`),
  KEY `uid_idx` (`uid`),
  KEY `name_idx` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `events` (
  `uid` smallint(5) unsigned NOT NULL,
  `date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `daemon` varchar(16) DEFAULT NULL,
  `event` text NOT NULL,
  `previous` text,
  `current` text
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `ftp` (
  `uid` smallint(5) unsigned NOT NULL,
  `username` varchar(22) NOT NULL,
  `directory` varchar(256) NOT NULL,
  `password` varchar(16) NOT NULL,
  `privs` tinyint(3) unsigned NOT NULL DEFAULT '0',
  PRIMARY KEY (`username`),
  KEY `uid` (`uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `limits` (
  `uid` smallint(5) unsigned NOT NULL,
  `db` tinyint(3) unsigned DEFAULT '30',
  `dbuser` tinyint(3) unsigned DEFAULT '60',
  `dns` tinyint(3) unsigned DEFAULT '30',
  `vhost` tinyint(3) unsigned DEFAULT '30',
  `ftp` tinyint(3) unsigned DEFAULT '30',
  `vpn` tinyint(3) unsigned DEFAULT '3',
  `quota_soft` smallint(5) unsigned DEFAULT NULL,
  `quota_hard` smallint(5) unsigned DEFAULT NULL,
  `max_children` smallint(5) unsigned DEFAULT '10',
  `start_servers` smallint(5) unsigned DEFAULT '2',
  `min_spare_servers` smallint(5) unsigned DEFAULT '2',
  `max_spare_servers` smallint(5) unsigned DEFAULT '6',
  `memcache_size` smallint(5) unsigned DEFAULT '32',
  `server` enum('shell','web','fastweb') DEFAULT NULL,
  `backup` tinyint(3) unsigned DEFAULT '10',
  `files` smallint(5) unsigned DEFAULT '256',
  PRIMARY KEY (`uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `uids` (
  `uid` smallint(2) unsigned NOT NULL,
  `id` smallint(2) unsigned NOT NULL,
  `login` varchar(20) CHARACTER SET utf8 NOT NULL,
  `shell` char(32) CHARACTER SET utf8 NOT NULL DEFAULT '/bin/bash',
  `password` char(100) COLLATE utf8_polish_ci DEFAULT NULL,
  `gid` smallint(5) unsigned DEFAULT '100',
  `server` enum('stallman','korn') CHARACTER SET utf8 NOT NULL,
  `date` date DEFAULT NULL,
  `valid` date DEFAULT NULL,
  `block` tinyint(1) DEFAULT '0',
  `suspend` tinyint(1) DEFAULT '0',
  `special` tinyint(1) DEFAULT '0',
  `sponsor` tinyint(1) DEFAULT '0',
  `test` tinyint(4) DEFAULT '0',
  `del` tinyint(1) DEFAULT '0',
  `authcode` char(16) COLLATE utf8_polish_ci DEFAULT NULL,
  PRIMARY KEY (`uid`),
  KEY `id` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_polish_ci;

CREATE TABLE `users` (
  `id` smallint(2) unsigned NOT NULL,
  `date` date DEFAULT NULL,
  `firstname` varchar(30) NOT NULL,
  `lastname` varchar(30) NOT NULL,
  `birth` date DEFAULT NULL,
  `type` enum('company','person') NOT NULL DEFAULT 'person',
  `lang` char(2) DEFAULT NULL,
  `vat` varchar(30) DEFAULT NULL,
  `phone` varchar(60) DEFAULT NULL,
  `company` varchar(90) DEFAULT NULL,
  `address` varchar(255) DEFAULT NULL,
  `postcode` varchar(10) DEFAULT NULL,
  `city` varchar(30) DEFAULT NULL,
  `country` varchar(2) DEFAULT NULL,
  `mail` varchar(60) NOT NULL,
  `discount` SMALLINT UNSIGNED DEFAULT '0',
  `know` enum('google','url','friend') DEFAULT NULL,
  `specify` varchar(80) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `mail` (`mail`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `vpn` (
  `uid` smallint(5) unsigned NOT NULL,
  `name` char(16) NOT NULL,
  `added_at` datetime DEFAULT NULL,
  `expires_at` datetime DEFAULT NULL,
  `status` smallint(6) DEFAULT NULL,
  `crt_file` text,
  `key_file` text,
  PRIMARY KEY (`uid`,`name`),
  KEY `uid` (`uid`),
  KEY `status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
