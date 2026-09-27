#!/usr/local/bin/tclsh9.0
# Create databases for overview and articles
# Overview db is used for all articles.
# Article db is only used for archived articles which are no longer available online.

set over_db /data/news_over.db
set arch_db /data2/news_archive.db

package require sqlite3

sqlite3 odb $over_db
sqlite3 adb $arch_db

# rowid in the groups table is used as a compact id for a group (grpid)
odb eval {CREATE TABLE groups(name TEXT PRIMARY KEY, posts INTEGER, servers TEXT)}

odb eval {CREATE TABLE over(grpid INTEGER, sub TEXT, frm TEXT, dat INTEGER, msgid TEXT, prev TEXT, xgrpids TEXT, PRIMARY KEY (grpid,msgid) ON CONFLICT IGNORE)}
# A better primary key above would be (msgid,grpid) but it's late to change now.
odb eval {CREATE INDEX over_gd ON over(grpid,dat)}
#odb eval {CREATE INDEX over_gn ON over(grpid,num)}
odb eval {CREATE INDEX over_gp ON over(grpid,prev)}

odb eval {CREATE TABLE counts(grpid INTEGER, server TEXT, last INTEGER, PRIMARY KEY (grpid,server) ON CONFLICT REPLACE)}

adb eval {CREATE TABLE arts(msgid TEXT PRIMARY KEY, txt TEXT)}
