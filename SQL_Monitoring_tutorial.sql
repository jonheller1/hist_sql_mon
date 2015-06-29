--------------------------------------------------------------------------------
-- This SQL Monitoring tutorial demonstrates how to use Real-Time SQL Monitoring
-- and when Historical SQL Monitoring can help.
--
-- This tutorial assumes you are familiar with basic Oracle tuning concepts,
-- like explain plans, join methods, etc.
--
-- This worksheet should be run in pieces in an IDE like PL/SQL Developer, Toad,
-- or SQL Developer.  (Sorry, SQL*Plus - you're not good enough for SQL tuning.)
--
-- Scenario #1 shows a cardinality (rows) estimate problem.
-- Scenario #2 shows a downgraded parallel query problem.
--------------------------------------------------------------------------------



--------------------------------------------------------------------------------
--#1: Bad Cardinality Estimate.
--------------------------------------------------------------------------------

--#1a: Clear out the schema to re-run the tutorial.
drop table small_table;
drop table medium_table;
drop table large_table;

--#1b: Create simple tables of different sizes, then gather statistics.
create table small_table (a number);
create table medium_table(a number);
create table large_table (a number);
insert into small_table  select level from dual connect by level <= 1;
insert into medium_table select level from dual connect by level <= 100;
insert into large_table  select level from dual connect by level <= 1000000;
begin
	dbms_stats.gather_table_stats(user, 'small_table' );
	dbms_stats.gather_table_stats(user, 'medium_table');
	dbms_stats.gather_table_stats(user, 'large_table' );
end;
/

--#1c: Simulate a statistics mistake.  Although Oracle has default tasks to
--gather statistics at night, it is important to manually gather statistics
--after a large data load.  It's a common mistake in a data warehouse to
--load a table but forget to manually gather statistics when the job is done.
insert into small_table  select level+1 from dual connect by level <= 100000;
commit;

--#1d: Run this statement to count the rows.  This will run for hours or days
--because of the bad optimizer statistics.  While it's running, go to step #1e
--in a separate session.
declare
	v_count number;
begin
	--Dynamic SQL is used to ensure the SQL_ID will be the same.
	execute immediate '
		select count(*) unique_string_to_search_for
		from small_table  st
		join medium_table mt on st.a = mt.a
		join large_table  lt on mt.a = lt.a
	'
	into v_count;
end;
/

--#1e: In a separate session, find the SQL_ID of the slow statement.
--The first step for tuning is to find what's slow.  This is much harder than
--most people realize.  If you're lucky, what's slow is a single SQL statement,
--and you can use a SQL statement like this to find it.  Note that there will
--be two rows, one for the PL/SQL block and one for the SQL statement.  You
--want to use the SQL_ID for the SQL statement.  Real-Time SQL Monitoring has
--a useful PL/SQL mode, but that's not demonstrated here.
select elapsed_time/1000000 seconds, sql_id, sql_text, users_executing, executions, gv$sql.*
from gv$sql
where users_executing > 0
order by elapsed_time desc;

--#1f: Run Real-Time SQL Monitoring on the slow statement.
--There are multiple "types".  I prefer "text" but you may want to try "active".
select dbms_sqltune.report_sql_monitor(
    sql_id => '70zg7uquwa4vj',
    type   => 'text'
) from dual;

--#1g: Take a brief look at the sample output.
SQL Monitoring Report

/*
SQL Text
------------------------------
select count(*) unique_string_to_search_for from small_table st join medium_table mt on st.a = mt.a join large_table lt on mt.a = lt.a

Global Information
------------------------------
 Status              :  EXECUTING                                         
 Instance ID         :  1                                                 
 Session             :  JHELLER (259:19376)                               
 SQL ID              :  70zg7uquwa4vj                                     
 SQL Execution ID    :  16777216                                          
 Execution Started   :  05/14/2015 01:18:40                               
 First Refresh Time  :  05/14/2015 01:18:46                               
 Last Refresh Time   :  05/14/2015 01:20:36                               
 Duration            :  116s                                              
 Module/Action       :  PL/SQL Developer/SQL Window - SQL_Monitoring_tuto 
 Service             :  orcl12                                            
 Program             :  plsqldev.exe                                      

Global Stats
=========================================
| Elapsed |   Cpu   |  Other   | Buffer |
| Time(s) | Time(s) | Waits(s) |  Gets  |
=========================================
|     116 |     115 |     1.11 |   1604 |
=========================================

SQL Plan Monitoring Details (Plan Hash Value=1118779715)
==============================================================================================================================================
| Id   |        Operation         |     Name     |  Rows   | Cost |   Time    | Start  | Execs |   Rows   | Mem | Activity | Activity Detail |
|      |                          |              | (Estim) |      | Active(s) | Active |       | (Actual) |     |   (%)    |   (# samples)   |
==============================================================================================================================================
|    0 | SELECT STATEMENT         |              |         |      |         5 |     +6 |     1 |        0 |     |          |                 |
|    1 |   SORT AGGREGATE         |              |       1 |      |         5 |     +6 |     1 |        0 |     |          |                 |
| -> 2 |    HASH JOIN             |              |       1 |  456 |       117 |     +0 |     1 |      100 |  2M |    44.83 | Cpu (52)        |
|    3 |     TABLE ACCESS FULL    | MEDIUM_TABLE |     100 |    3 |         1 |     +6 |     1 |      100 |     |          |                 |
| -> 4 |     MERGE JOIN CARTESIAN |              |      1M |  450 |       111 |     +6 |     1 |       1G |     |          |                 |
| -> 5 |      TABLE ACCESS FULL   | SMALL_TABLE  |       1 |    3 |       111 |     +6 |     1 |     1371 |     |          |                 |
| -> 6 |      BUFFER SORT         |              |      1M |  447 |       116 |     +1 |  1371 |       1G | 32M |    55.17 | Cpu (64)        |
|    7 |       TABLE ACCESS FULL  | LARGE_TABLE  |      1M |  447 |         1 |     +6 |     1 |       1M |     |          |                 |
==============================================================================================================================================
*/


--#1h: Interpret results.
/*
You've probably seen most of this information before in GV$SQL and explain plans.
The important new columns are "Activity (%)", "Activity Detail (# samples)", and "Rows (Actual)".

- "Activity (%)": This lets you instantly drill-down to the slow operation.
  With this small explain plan it doesn't help much.  For realistic explain plans
  it helps you ignore the irrelevant parts of the query and focus on the problem.
- "Activity Detail (# samples)": This tells you what the operations were waiting on.
  In this example, the waits are only on CPU.  That doesn't help much, but it
  does let you rule out IO problems.
- "Rows (Actual)": This helps uncover the root cause of bad optimizer decisions.
  The cardinality, the number of rows, affects many important decisions.  For
  example, an index is probably useful if it returns 1% of the rows but not
  useful if it returns 99% of the rows.  A bad cardinality decision can cascade
  and cause performance problem many operations later.  Look for the largest
  cardinality difference early in the execution plan.  The largest difference is
  based on the ratio, not the absolute number.  In this case, Id #5 is the worst
  because there are 3 orders of magnitude difference between the estimate (1)
  and the actual (1371).  Execution plan estimates always display at least 1 but
  the real estimate may be something like 0.00001.

Based on the above information, the main problem appears to be a bad cardinality
estimate for Plan ID #5, a full table scan of SMALL_TABLE.  Looking at the query
shows there are no predicates on that table.  The optimizer thinks that table has
one row when it really has much more.  This implies the statistics are incorrect
for that table and need to be re-gathered.
*/

--#1i: Run Historical SQL Monitoring on the results.
select hist_sql_mon.hist_sql_mon(
	p_sql_id => '70zg7uquwa4vj',
	p_start_time_filter => sysdate - interval '1' hour,
	p_end_time_filter => sysdate
) from dual;

/*
Historical SQL Monitoring 1.2.1 (when Real-Time SQL Monitoring does not work)

Monitoring Metadata
------------------------------ 
 Report Created Date : 2015-06-29 13:38:05
 Report Created by   : JHELLER
 SQL_ID              : 70zg7uquwa4vj
 SQL_TEXT            :  select count(*) unique_string_to_search_for from small_table st join medium_table mt on st.a
 P_START_TIME_FILTER : 2015-06-29 12:38:05
 P_END_TIME_FILTER   : 2015-06-29 13:38:05


Plan hash value: 1118779715
Start Time     : 2015-06-29 13:35:36
End Time       : 2015-06-29 13:37:32
Source         : Data came from GV$ACTIVE_SESSION_HISTORY only.  Counts from GV$ACTIVE_SESSION_HISTORY are divided by 10 to match sampling frequency of historical data.
 
---------------------------------------------------------------------------------------===============================================================
| Id  | Operation              | Name         | Rows  | Bytes | Cost (%CPU)| Time     | Activity (%) | Activity Detail (# samples|# distinct samples)|
---------------------------------------------------------------------------------------===============================================================
|   0 | SELECT STATEMENT       |              |       |       |   456 (100)|          |              |                                               |
|   1 |  SORT AGGREGATE        |              |     1 |    11 |            |          |              |                                               |
|*  2 |   HASH JOIN            |              |     1 |    11 |   456   (2)| 00:00:01 |        53.85 | Cpu (7|7)                                     |
|   3 |    TABLE ACCESS FULL   | MEDIUM_TABLE |   100 |   300 |     3   (0)| 00:00:01 |              |                                               |
|   4 |    MERGE JOIN CARTESIAN|              |  1000K|  7812K|   450   (1)| 00:00:01 |              |                                               |
|   5 |     TABLE ACCESS FULL  | SMALL_TABLE  |     1 |     3 |     3   (0)| 00:00:01 |              |                                               |
|   6 |     BUFFER SORT        |              |  1000K|  4882K|   447   (1)| 00:00:01 |        46.15 | Cpu (6|6)                                     |
|   7 |      TABLE ACCESS FULL | LARGE_TABLE  |  1000K|  4882K|   447   (1)| 00:00:01 |              |                                               |
---------------------------------------------------------------------------------------===============================================================
 
Predicate Information (identified by operation id):
---------------------------------------------------
 
   2 - access("MT"."A"="LT"."A" AND "ST"."A"="MT"."A")
*/

--#1j: Interpret results.
/*

Interpreting Historical SQL Monitoring is similar to Real-Time SQL Monitoring.
There's not quite as much information so this process is more difficult and
involves more guessing.

The largest Activity (%) is on Plan Id #2.  The estimate is 1 Row.  Although
we don't have the actual number of rows, the Activity (%) strongly implies that
the number of rows is much greater than 1.  So we know that something underneath
that step is probably wrong.  Looking for other potentially incorrect "1"s, and
a good skepticism of any "MERGE JOIN CARTESIAN" should lead to the same
conclusion - the statistics are wrong for SMALL_TABLE.
*/





--------------------------------------------------------------------------------
--#2: Downgraded Parallel Query.
--------------------------------------------------------------------------------


--#2: TODO
--#2a: Simulate a parallelism problem.
--Open a separate session in your IDE, run this, but don't retreive all results.
--This simulates a long-running parallel query that uses all parallel resources.
--You may need to run this multiple times depending on parallel limitations.
select /*+ parallel(1000) */ * from dba_objects;


--Use all but 2 of the parallel threads.
--(This assumes no other parallel operations are running, there is no parallel
-- queueing, resource manager restrictions, profile restrictions, etc.)	
declare
	v_dop number;
	parallel_cursor sys_refcursor;
	v_result number;
begin
	--Determin DOP.
	select value-2
	into v_dop
	from v$parameter
	where name = 'parallel_max_servers';

	--Open a parallel cursor that uses all but 2 of the threads.
	open parallel_cursor for 'select /*+ parallel('||v_dop||') */ 1 a from small_table';

	--Get the first row and pause, using all the parallel servers.
	loop
		fetch parallel_cursor into v_result;
		dbms_lock.sleep(100000);
	end loop;
end;
/

--TODO




