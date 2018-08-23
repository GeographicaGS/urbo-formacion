/*
* Script to load all PL/PgSQL functions
*/

-- DDL
\ir common/ddl/urbo_createtables_students.sql

-- DML
\ir common/dml/urbo_createmetadata_students.sql

-- Processing functions
\ir common/urbo_students_calculate_distances.sql
