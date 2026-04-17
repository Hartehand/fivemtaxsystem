-- DOJ Finance Suite: Hilfstabellen für Workflow, Mapping, Fristen, Verknüpfungen und Reports

CREATE TABLE IF NOT EXISTS `doj_finance_reviews` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `source_type` VARCHAR(64) NOT NULL,
  `source_id` BIGINT NULL,
  `source_key` VARCHAR(191) NULL,
  `status` VARCHAR(32) NOT NULL DEFAULT 'neu',
  `assigned_to` VARCHAR(128) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_source_review` (`source_type`, `source_id`, `source_key`),
  KEY `idx_source_type` (`source_type`),
  KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_notes` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `review_id` BIGINT UNSIGNED NOT NULL,
  `source_type` VARCHAR(64) NOT NULL,
  `source_id` BIGINT NULL,
  `source_key` VARCHAR(191) NULL,
  `author_identifier` VARCHAR(100) NOT NULL,
  `note` TEXT NOT NULL,
  `is_internal` TINYINT(1) NOT NULL DEFAULT 1,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_review_id` (`review_id`),
  KEY `idx_source_ref` (`source_type`, `source_id`, `source_key`),
  CONSTRAINT `fk_finance_notes_review`
    FOREIGN KEY (`review_id`) REFERENCES `doj_finance_reviews` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_reports` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `report_type` VARCHAR(64) NOT NULL,
  `title` VARCHAR(191) NOT NULL,
  `created_by` VARCHAR(100) NOT NULL,
  `range_from` DATE NULL,
  `range_to` DATE NULL,
  `summary` LONGTEXT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_report_type` (`report_type`),
  KEY `idx_created_by` (`created_by`),
  KEY `idx_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_report_entries` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `report_id` BIGINT UNSIGNED NOT NULL,
  `line_no` INT NOT NULL,
  `source_type` VARCHAR(64) NULL,
  `source_id` BIGINT NULL,
  `source_key` VARCHAR(191) NULL,
  `label` VARCHAR(255) NOT NULL,
  `amount` DECIMAL(18,2) NOT NULL DEFAULT 0,
  `payload` LONGTEXT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_report_line` (`report_id`, `line_no`),
  KEY `idx_source_ref` (`source_type`, `source_id`, `source_key`),
  CONSTRAINT `fk_finance_report_entries_report`
    FOREIGN KEY (`report_id`) REFERENCES `doj_finance_reports` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_deadlines` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `source_type` VARCHAR(64) NOT NULL,
  `source_id` BIGINT NULL,
  `source_key` VARCHAR(191) NULL,
  `due_date` DATE NOT NULL,
  `is_overridden` TINYINT(1) NOT NULL DEFAULT 0,
  `reason` VARCHAR(255) NULL,
  `updated_by` VARCHAR(100) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_deadline_source` (`source_type`, `source_id`, `source_key`),
  KEY `idx_due_date` (`due_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_auditlog` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `source_type` VARCHAR(64) NOT NULL,
  `source_id` BIGINT NULL,
  `source_key` VARCHAR(191) NULL,
  `action` VARCHAR(64) NOT NULL,
  `actor_identifier` VARCHAR(100) NOT NULL,
  `payload` LONGTEXT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_source_ref` (`source_type`, `source_id`, `source_key`),
  KEY `idx_action` (`action`),
  KEY `idx_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_links` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `business_job` VARCHAR(64) NOT NULL,
  `period` VARCHAR(20) NULL,
  `transaction_id` BIGINT NULL,
  `tax_source_type` VARCHAR(64) NULL,
  `tax_source_id` BIGINT NULL,
  `tax_source_key` VARCHAR(191) NULL,
  `match_quality` ENUM('eindeutig','wahrscheinlich','manuell_pruefen') NOT NULL DEFAULT 'manuell_pruefen',
  `comment` VARCHAR(255) NULL,
  `created_by` VARCHAR(100) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_business_job_period` (`business_job`, `period`),
  KEY `idx_transaction_id` (`transaction_id`),
  KEY `idx_tax_source` (`tax_source_type`, `tax_source_id`, `tax_source_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_business_map` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `tax_job` VARCHAR(64) NOT NULL,
  `business_id` VARCHAR(64) NOT NULL,
  `alias` VARCHAR(64) NULL,
  `created_by` VARCHAR(100) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_tax_job` (`tax_job`),
  KEY `idx_business_id` (`business_id`),
  KEY `idx_alias` (`alias`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `doj_finance_transaction_map` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `transaction_table` VARCHAR(64) NOT NULL,
  `transaction_id` BIGINT NOT NULL,
  `business_id` VARCHAR(64) NOT NULL,
  `assignment_mode` ENUM('manual','automatic','suggested') NOT NULL DEFAULT 'manual',
  `comment` VARCHAR(255) NULL,
  `assigned_by` VARCHAR(100) NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_tx_map` (`transaction_table`, `transaction_id`),
  KEY `idx_business_id` (`business_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
