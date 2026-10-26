CREATE TABLE `readings` (
	`device_id` text NOT NULL,
	`timestamp` text NOT NULL,
	`power_w` real NOT NULL,
	`energy_kwh` real NOT NULL,
	`source` text NOT NULL,
	`received_at` text NOT NULL,
	PRIMARY KEY(`device_id`, `timestamp`)
);
--> statement-breakpoint
CREATE TABLE `settings` (
	`id` text PRIMARY KEY NOT NULL,
	`value` text NOT NULL
);
