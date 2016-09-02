`HIST_SQL_MON` 1.2.2
============

Historical SQL Monitoring is an advanced performance tuning tool for Oracle databases.

It resolves some limitations of [Real-Time SQL Monitoring](http://www.oracle.com/technetwork/database/manageability/sqlmonitor-084401.html) and assumes familiarity with that tool.  For example, Real-Time SQL Monitoring data ages out quickly, sometimes even while the query is executing.  Historical SQL Monitoring uses AWR to re-construct similar information.  Although it doesn't have as much information as Real-Time SQL Monitoring, it has the most important features:

* **Real numbers, not just estimates.**  Explain plans are helpful but they still leave you guessing at which operation is the slowest.  You should never have to guess where a statement is slow.
* **Data aggregated at the operation level.**  Many tools, like AWR reports, only aggregate information for a time period or for a SQL statement.  In a data warehouse a single query often runs for many hours.  It is crucial to drill down to the lowest level, the operation.


## Simple Example

    select hist_sql_mon.hist_sql_mon(
        p_sql_id            => '2ssrz4j1m39wx',
        p_start_time_filter => date '2014-09-25',
        p_end_time_filter   => sysdate - interval '1' day)
    from dual;

The primary output is a CLOB containing an execution plan with a count and distinct count of events.

    ------------------------------------------------------------------------===============================================================
    | Id  | Operation               | Name     | Rows  | Bytes |Cost (%CPU)| Activity (%) | Activity Detail (# samples|# distinct samples)|
    ------------------------------------------------------------------------===============================================================
    |   0 | SELECT STATEMENT        |          |       |       |  212K(100)|              |                                               |
    |   1 |  SORT AGGREGATE         |          |     1 |   224 |           |              |                                               |
    |   2 |   HASH JOIN RIGHT OUTER |          |    11M|  2552M|  212K  (1)|         9.09 | Cpu (1|1), Cpu (1|1)                          |
    |   3 |    TABLE ACCESS FULL    | SEG$     |  7245 | 79695 |   59   (0)|              |                                               |
    |   4 |    HASH JOIN RIGHT OUTER|          |    10M|  2111M|  212K  (1)|         9.09 | Cpu (1|1)                                     |
    |   5 |     INDEX FULL SCAN     | I_USER2  |   140 |   560 |    1   (0)|              |                                               |
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

See SQL_Monitoring_tutorial.sql for a more thorough example.


## How to Install

    @hist_sql_mon.pck
    --The below steps are optional:
    create public synonym hist_sql_mon for hist_sql_mon;
    grant execute on hist_sql_mon to public;


## How to Get Help
Create a Github issue.  Or send an email to the creator, Jon Heller, at jonearles@yahoo.com


## Alternatives

The Oracle 12c Database Express Performance Hub includes Monitored SQL in historical mode.  But `hist_sql_mon` may still be useful in 12c since SQL Monitoring has unresolved bugs and will not always correctly monitor statements.


## License
`hist_sql_mon` is licensed under the LGPLv3.
