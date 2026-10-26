import { sqliteTable, text, real, primaryKey } from 'drizzle-orm/sqlite-core';
export const readings = sqliteTable('readings', {deviceId:text('device_id').notNull(),timestamp:text('timestamp').notNull(),power:real('power_w').notNull(),energy:real('energy_kwh').notNull(),source:text('source').notNull(),receivedAt:text('received_at').notNull()},t=>[primaryKey({columns:[t.deviceId,t.timestamp]})]);
export const settings = sqliteTable('settings', {id:text('id').primaryKey(),value:text('value').notNull()});
