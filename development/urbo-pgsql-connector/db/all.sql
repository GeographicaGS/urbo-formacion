--
-- Copyright 2017 Telefónica Digital España S.L.
--
-- This file is part of URBO PGSQL connector.
--
-- URBO PGSQL connector is free software: you can redistribute it and/or
-- modify it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- URBO PGSQL connector is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
-- General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with URBO PGSQL connector. If not, see http://www.gnu.org/licenses/.
--
-- For those usages not covered by this license please contact with
-- iot_support at tid dot es
--

-- DATABASE PARAMETERS
\set dbname urbo
\set password urbo
\set owner urbo_admin

-- API LOGIN PARAMETERS
\set admin_email 'admin@geographica.gs'
\set admin_pwd 'admin'

-- CREATE URBO ADMIN USER AND CONNECT TO THE NEW DATABASE
\ir createdb.sql
\c :dbname

-- SET UP NECESSARY TABLES AND FUNCTIONS FOR URBO
\ir createtables.sql
