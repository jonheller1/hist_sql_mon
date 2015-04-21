`HIST_SQL_MON`
============

Historical SQL Monitoring is a performance tuning tool for Oracle data warehouses.

It resolves some limitations of [Real-Time SQL Monitoring](http://www.oracle.com/technetwork/database/manageability/sqlmonitor-084401.html).  For example, Real-Time SQL Monitoring data ages out quickly, sometimes even while the query is executing.  Historical SQL Monitoring uses AWR to re-construct similar information.  Although it doesn't have as much information as Real-Time SQL Monitoring, it has the most important features:

* **Real numbers, not just estimates.**  Explain plans are helpful but they still leave you guessing at which operation is the slowest.  You should never have to guess where a statement is slow.
* **Data aggregated at the operation level.**  Many tools, like AWR reports, only aggregate information for a time period or for a SQL statement.  In a data warehouse a single query often runs for many hours.  It is crucial to drill down to the lowest level, the operation.


## Example

    select hist_sql_mon.hist_sql_mon(
        p_sql_id            => '2ssrz4j1m39wx',
        p_start_time_filter => date '2014-09-25',
        p_end_time_filter   => sysdate - interval '1' day)
    from dual;

The primary output is a CLOB containing an execution plan with a count and distinct count of events.

    ----------------------------------------------------------------------=============================|
    | Id  | Operation              | Name   | Rows  | Bytes | Cost (%CPU)| Event (count|distinct count)|
    ----------------------------------------------------------------------=============================|
    |   0 | SELECT STATEMENT       |        |       |       | 83031 (100)|                             |
    |   1 |  SORT AGGREGATE        |        |     1 |   234 |            |                             |
    |   2 |   HASH JOIN RIGHT OUTER|        |  8116K|  1811M| 83031   (4)| Cpu (25|25)                 |
    |   3 |    INDEX FULL SCAN     | I_USER2|   155 |   620 |     1   (0)|                             |
    |   4 |    NESTED LOOPS OUTER  |        |  8116K|  1780M| 82993   (4)| Cpu (1|1)                   |
    |   5 |     NESTED LOOPS OUTER |        |  8116K|  1718M| 10702  (24)| Cpu (2|2)                   |
    ...

The functions also print the SQL statement to DBMS_OUTPUT.  The bind variables are replaced with hard-coded values so the query can run anywhere.  This can help with debugging or creating your own queries.

    ----------------------------------
    --Historical SQL Monitoring Report
    ----------------------------------
    --Execution plans and ASH data, where there is at least some samples for a plan_hash_value.
    select
    	--Add execution metadata.
    	case
    		when plan_table_output like 'Plan hash value: %' then
    ...


## How to Install

    @hist_sql_mon.pck
    --The below steps are optional:
    create public synonym hist_sql_mon for hist_sql_mon;
    grant execute on hist_sql_mon to public;


## How to Get Help
Create a Github issue.  Or send an email to the creator, Jon Heller, at jonearles@yahoo.com


## Alternatives

Oracle 12c has a Performance Hub, which includes Monitored SQL in historical mode.  But this program will still likely be useful in 12c since SQL Monitoring has unresolved bugs and will not always correctly monitor statements.


## License
`hist_sql_mon` is licensed under the LGPLv3.
