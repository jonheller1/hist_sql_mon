create or replace package hist_sql_mon authid current_user is

C_VERSION constant varchar2(100) := '0.1.0';

/*


Requirements: TODO
Licensing requirements: diagnostics pack.

Privilege Requirements:
	Run as SYS:
		grant select on v_$parameter to <install_schema>;
		grant select on gv_$active_session_history to <install_schema>;
		grant select on dba_hist_active_sess_history to <install_schema>;
		grant select on dba_hist_sqltext to <install_schema>;

TODO:
	What about DBMS_SQL_MONITOR?
*/



/*
	Purpose: Extend Real-Time SQL Monitoring to Historical SQL Monitoring.  Uses AWR information
		to recreate results similar to REPORT_SQL_MONITOR.

		The paramount task of performance tuning is to focus on what is slow.  Most methods focus
		on a period of time or aggregate tasks at a high level.  In a DSS or DW system an individual
		SQL statement may run for hours or days.  This method aggregates wait events and time at
		an operation level.  This makes it clear which part of a SQL statement is slow, and why.

	Parameters:
		sql_id - SQL_ID to monitor.
		start|end_time_filter - Period of time to monitor.  If blank, will find last contiguous
			execution of the statement.
*/
function hist_sql_mon(
	p_sql_id                    IN VARCHAR2,
	p_start_time_filter         IN DATE      DEFAULT  NULL,
	p_end_time_filter           IN DATE      DEFAULT  NULL
	)
return clob;


--Parameters are identical to DBMS_SQLTUNE.REPORT_SQL_MONITOR:
--http://docs.oracle.com/cd/E11882_01/appdev.112/e40758/d_sqltun.htm#ARPLS68444
function REPORT_SQL_MONITOR(
	sql_id                    IN VARCHAR2  DEFAULT  NULL,
	session_id                IN NUMBER    DEFAULT  NULL,
	session_serial            IN NUMBER    DEFAULT  NULL,
	sql_exec_start            IN DATE      DEFAULT  NULL,
	sql_exec_id               IN NUMBER    DEFAULT  NULL,
	inst_id                   IN NUMBER    DEFAULT  NULL,
	start_time_filter         IN DATE      DEFAULT  NULL,
	end_time_filter           IN DATE      DEFAULT  NULL,
	instance_id_filter        IN NUMBER    DEFAULT  NULL,
	parallel_filter           IN VARCHAR2  DEFAULT  NULL,
	plan_line_filter          IN NUMBER    DEFAULT  NULL,
	event_detail              IN VARCHAR2  DEFAULT  'YES',
	bucket_max_count          IN NUMBER    DEFAULT  128,
	bucket_interval           IN NUMBER    DEFAULT  NULL,
	base_path                 IN VARCHAR2  DEFAULT  NULL,
	last_refresh_time         IN DATE      DEFAULT  NULL,
	report_level              IN VARCHAR2  DEFAULT 'TYPICAL',
	type                      IN VARCHAR2  DEFAULT 'TEXT',
	sql_plan_hash_value       IN NUMBER    DEFAULT  NULL,
	--12c undocumented parameters - "NULL" is a guess
	con_name                  IN VARCHAR2  DEFAULT  NULL,
	report_id                 IN NUMBER    DEFAULT  NULL,
	dbop_name                 IN VARCHAR2  DEFAULT  NULL,
	dbop_exec_id              IN NUMBER    DEFAULT  NULL
	)
RETURN CLOB;



end;
/
create or replace package body hist_sql_mon is

--What is the source of the request?  This is useful for printing messages.
C_SOURCE_DIRECT constant varchar2(100) := 'Results were directly requested from user.';
C_SOURCE_DONE_ERROR constant varchar2(100) := 'REPORT_SQL_MONITOR finished with Done (Error).';
C_SOURCE_NO_RESULTS constant varchar2(100) := 'REPORT_SQL_MONITOR did not display any results.';


C_HIST_SQL_MON_SQL constant varchar2(32767) :=
q'<
----------------------------------
--Historical SQL Monitoring Report
----------------------------------
--Execution plans and ASH data, where there is at least some samples for a plan_hash_value.
select
	--Add execution metadtaa.
	case
		when plan_table_output like 'Plan hash value: %' then
			plan_table_output||chr(10)||
			'Start Time: '||to_char(min_sample_time, 'YYYY-MM-DD HH24:MI:SS')||chr(10)||
			'End Time: '||to_char(max_sample_time, 'YYYY-MM-DD HH24:MI:SS')||chr(10)
		else
			plan_table_output
	end plan_table_output
--	bulk collect into v_output_lines
from
(
	--Execution plans and ASH data.
	select
		plan_table_output
			||
			case
				when plan_table_output like '| Id  |%' then ' Event (count|distinct count)'
				when ash_string is not null then ' '||ash_string
			end plan_table_output
		,count(ash_string) over (partition by execution_plans.plan_hash_value) count_per_hash
		,execution_plans.plan_hash_value, execution_plans.rownumber
		,min(min_sample_time) over (partition by execution_plans.plan_hash_value) min_sample_time
		,max(max_sample_time) over (partition by execution_plans.plan_hash_value) max_sample_time
	from
	(
		-----------------
		--Execution plans
		-----------------
		--Use DISPLAY_CURSOR if possible, else use DISPLAY_AWR.
		select last_plan_hash_value plan_hash_value, plan_table_output, rownumber
			,case
				when regexp_like(plan_table_output, '\|\s*[0-9]* \|.*') then
					to_number(replace(substr(plan_table_output, 2, 5), '*', null))
				else
					null
			end sql_plan_line_id
		from
		(
			--Exclude repetitive SQL information, count if PLAN_HASH_VALUE has both a cursor and an awr version.
			select plan_hash_sql_id.*
				,count(distinct cursor_or_awr) over (partition by last_plan_hash_value) has_both_cursor_and_awr_if_2
			from
			(
				--Latest Plan Hash Value and SQL_ID line.
				select
					cursor_or_awr
					,rownumber
					,last_value(case when plan_table_output like 'Plan hash value: %' then substr(plan_table_output, 18) end ignore nulls)
						over (partition by cursor_or_awr order by rownumber) last_plan_hash_value
					,last_value(case when plan_table_output like 'SQL_ID %' then rownumber else null end ignore nulls)
						over (partition by cursor_or_awr order by rownumber) last_sql_id_plan
					,plan_table_output
				from
				(
					--Raw execution plan data.
					select 'cursor' cursor_or_awr, rownum rownumber, plan_table_output
					from table(dbms_xplan.display_cursor(sql_id => :p_sql_id))
					union all
					select 'awr'    cursor_or_awr, rownum rownumber, plan_table_output
					from table(dbms_xplan.display_awr(sql_id => :p_sql_id))
				) raw_execution_plan_data
			) plan_hash_sql_id
			--Remove the repetitive "SQL_ID ...." text at the top.
			where rownumber >= last_sql_id_plan + 4
			order by rownumber
		) exclude_repetitive_sql
		where cursor_or_awr = 'cursor' or has_both_cursor_and_awr_if_2 = 1
		order by cursor_or_awr, rownumber
	) execution_plans
	left join
	(
		-----------
		--ASH data.
		-----------
		select sql_plan_hash_value, sql_plan_line_id, min_sample_time, max_sample_time
			,listagg(event||' ('||sample_count||'|'||sample_distinct_count||')', ', ')
				within group (order by sample_count desc) ash_string
		from
		(
			--ASH summary.
			select sql_plan_hash_value, sql_plan_line_id, event
				,count(*) sample_count
				,count(distinct sample_time) sample_distinct_count
				,min(sample_time) min_sample_time
				,max(sample_time) max_sample_time
			from
			(
				--ASH raw data.
				select sql_plan_hash_value, sql_plan_line_id, nvl(event, 'Cpu') event, sample_time
				from gv$active_session_history
				where sql_id = :p_sql_id
				--TODO: Filter time
				union all
				select sql_plan_hash_value, sql_plan_line_id, nvl(event, 'Cpu') event, sample_time
				from dba_hist_active_sess_history
				where sql_id = :p_sql_id
				--TODO: Filter time
			) ash_raw_data
			group by sql_plan_hash_value, sql_plan_line_id, event
			order by sql_plan_hash_value, sql_plan_line_id, count(*)
		) ash_summary
		group by sql_plan_hash_value, sql_plan_line_id, min_sample_time, max_sample_time
	) ash_data
		on execution_plans.plan_hash_value = ash_data.sql_plan_hash_value
		and execution_plans.sql_plan_line_id = ash_data.sql_plan_line_id
	order by execution_plans.plan_hash_value, execution_plans.rownumber
) execution_plans_and_ash_data
where count_per_hash > 0
order by plan_hash_value, rownumber
>'; --' Fix PL/SQL Developer parsing bug.




------------------------------------------------------------------------------------------------------------------------
--Purpose: Raise exception if diagnostic and tuning packs are not licensed.
procedure check_diag_and_tuning_license is
	v_license varchar2(4000);
begin
	select value into v_license from v$parameter where name = 'control_management_pack_access';

	if v_license <> 'DIAGNOSTIC+TUNING' then
		raise_application_error(-20000, 'This procedure requires the diagnostic and tuning pack.  The parameter '||
			'control_management_pack_access must be set to ''DIAGNOSTIC+TUNING'', the current value is '||
			v_license||'.');
	end if;
end check_diag_and_tuning_license;


------------------------------------------------------------------------------------------------------------------------
--Purpose: Raise exception if diagnostic pack is not licensed.
procedure check_diag_license is
	v_license varchar2(4000);
begin
	select value into v_license from v$parameter where name = 'control_management_pack_access';

	if v_license not in ('DIAGNOSTIC+TUNING', 'DIAGNOSTIC') then
		raise_application_error(-20000, 'This procedure requires the diagnostic pack.  The parameter '||
			'control_management_pack_access must be set to ''DIAGNOSTIC+TUNING'' or ''DIAGNOSTIC'', the '||
			'current value is '||v_license||'.');
	end if;
end check_diag_license;


------------------------------------------------------------------------------------------------------------------------
--Purpose: Determine if the report was generated or not.  Detection is different for each type.
function is_report_generated(type in varchar2, p_clob in out nocopy clob) return boolean is
begin
	return
		case
			--Type can be any case but cannot have whitespace.
			when p_clob is null then true
			when upper(type) = 'text'   and p_clob = 'SQL Monitoring Report' then true
			when upper(type) = 'html'   and dbms_lob.instr(p_clob, '<h1 align="center">SQL Monitoring Report</h1>'||chr(10)||'  </body>') > 1 then true
			when upper(type) = 'xml'    and dbms_lob.instr(p_clob, '</report_id>'||chr(10)||'</report>') > 1 then true
			when upper(type) = 'active' and dbms_lob.instr(p_clob, '</report_id>'||chr(10)||'</report>') > 1 then true
			else false
		end;
end is_report_generated;


------------------------------------------------------------------------------------------------------------------------
--Purpose: Determine if the report was generated or not.  Detection is different for each type.
function get_hist_sql_mon_header(p_sql_id in varchar2, p_start_time_filter date, p_end_time_filter date
	,p_source in varchar2)
return clob is
	v_header clob;
	v_reason varchar2(100);
	v_sql_text_first_100_char varchar2(100);
begin
	--Title
	v_header := q'<Historical SQL Monitoring (when Real-Time SQL Monitoring doesn't work)>'||chr(10)||chr(10);

	--SQL Text.  Replace new-lines so that text is all on one line.
	select regexp_replace(replace(substr(sql_text, 1, 100), chr(10), null), '\s+', ' ')
	into v_sql_text_first_100_char
	from dba_hist_sqltext
	where sql_id = p_sql_id;

	--Reason called
	if p_source = C_SOURCE_DIRECT then
		v_reason := 'Historical SQL Monitoring was directly called.';
	elsif p_source = C_SOURCE_DONE_ERROR then
		v_reason := 'Real-Time SQL Monitoring had error.  This usually happens when a single operation takes more than 30 minutes.';
	elsif p_source = C_SOURCE_NO_RESULTS then
		v_reason := 'Real-Time SQL Monitoring had no results.  This usually happens when data ages out.';
	end if;

	--Print monitoring metadata.
	v_header := v_header||
		'Monitoring Metadata'||chr(10)||
		'------------------------------ '||chr(10)||
		' Reason Called       : '||v_reason||chr(10)||
		' Report Created Date : '||to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS')||chr(10)||
		' Report Created by   : '||user||chr(10)||
		' SQL_ID              : '||p_sql_id||chr(10)||
		' SQL_TEXT            : '||v_sql_text_first_100_char||chr(10)||
		' P_START_TIME_FILTER : '||nvl(to_char(p_start_time_filter, 'YYYY-MM-DD HH24:MI:SS'), 'NULL')||chr(10)||
		' P_END_TIME_FILTER   : '||nvl(to_char(p_end_time_filter, 'YYYY-MM-DD HH24:MI:SS'), 'NULL')||chr(10)||chr(10)||chr(10);

	return v_header;
end get_hist_sql_mon_header;


------------------------------------------------------------------------------------------------------------------------
function hist_sql_mon(
	p_sql_id                    IN VARCHAR2,
	p_start_time_filter         IN DATE      DEFAULT  NULL,
	p_end_time_filter           IN DATE      DEFAULT  NULL,
	p_source                    IN VARCHAR2
	)
return clob is
	v_output_lines sys.odcivarchar2list;
	v_output_clob clob;
	v_sql clob;
begin
	--Check license.
	check_diag_license;

	--Find time period.
	--TODO

	--Get header.
	v_output_clob := get_hist_sql_mon_header(p_sql_id, p_start_time_filter, p_end_time_filter, p_source);

	--Execute statement.
	execute immediate C_HIST_SQL_MON_SQL
	bulk collect into v_output_lines
	using p_sql_id, p_sql_id, p_sql_id, p_sql_id;

	--Print it out for debugging.
	--Since some tools have 4K limit, split it up around first linefeed after 3800.
	v_sql := replace(C_HIST_SQL_MON_SQL, ':p_sql_id', ''''||p_sql_id||'''');
	dbms_output.enable(1000000);
	dbms_output.put_line(substr(v_sql, 1, instr(v_sql, chr(10), 3800)-1));
	dbms_output.put_line(substr(v_sql, instr(v_sql, chr(10), 3800)+1));

	--Convert lines to CLOB.
	for i in 1 .. v_output_lines.count loop
		v_output_clob := v_output_clob || v_output_lines(i) || chr(10);
	end loop;

	return v_output_clob;
end;


------------------------------------------------------------------------------------------------------------------------
--Purpose: Public function just to call private function with inferred source.
function hist_sql_mon(
	p_sql_id                    IN VARCHAR2,
	p_start_time_filter         IN DATE      DEFAULT  NULL,
	p_end_time_filter           IN DATE      DEFAULT  NULL
	)
return clob is
begin
	return hist_sql_mon(p_sql_id, p_start_time_filter, p_end_time_filter, C_SOURCE_DIRECT);
end hist_sql_mon;


------------------------------------------------------------------------------------------------------------------------
/*
Use Real Time SQL Monitoring if possible.  If not available, return Historical SQL Monitoring.
Parameters: Same as DBMS_SQLTUNE.REPORT_SQL_MONITOR.
Requires: The diagnostics AND the tuning pack.
*/
function REPORT_SQL_MONITOR(
	sql_id                    IN VARCHAR2  DEFAULT  NULL,
	session_id                IN NUMBER    DEFAULT  NULL,
	session_serial            IN NUMBER    DEFAULT  NULL,
	sql_exec_start            IN DATE      DEFAULT  NULL,
	sql_exec_id               IN NUMBER    DEFAULT  NULL,
	inst_id                   IN NUMBER    DEFAULT  NULL,
	start_time_filter         IN DATE      DEFAULT  NULL,
	end_time_filter           IN DATE      DEFAULT  NULL,
	instance_id_filter        IN NUMBER    DEFAULT  NULL,
	parallel_filter           IN VARCHAR2  DEFAULT  NULL,
	plan_line_filter          IN NUMBER    DEFAULT  NULL,
	event_detail              IN VARCHAR2  DEFAULT  'YES',
	bucket_max_count          IN NUMBER    DEFAULT  128,
	bucket_interval           IN NUMBER    DEFAULT  NULL,
	base_path                 IN VARCHAR2  DEFAULT  NULL,
	last_refresh_time         IN DATE      DEFAULT  NULL,
	report_level              IN VARCHAR2  DEFAULT 'TYPICAL',
	type                      IN VARCHAR2  DEFAULT 'TEXT',
	sql_plan_hash_value       IN NUMBER    DEFAULT  NULL,
	--12c undocumented parameters - "NULL" is a guess
	con_name                  IN VARCHAR2  DEFAULT  NULL,
	report_id                 IN NUMBER    DEFAULT  NULL,
	dbop_name                 IN VARCHAR2  DEFAULT  NULL,
	dbop_exec_id              IN NUMBER    DEFAULT  NULL
	)
RETURN CLOB is
	v_clob clob;
begin
	check_diag_and_tuning_license;

	--Try to use Real Time SQL Monitoring.
	v_clob := dbms_sqltune.report_sql_monitor(sql_id,session_id,session_serial,sql_exec_start,sql_exec_id,inst_id,
		start_time_filter,end_time_filter,instance_id_filter,parallel_filter,plan_line_filter,event_detail,
		bucket_max_count,bucket_interval,base_path,last_refresh_time,report_level,type,sql_plan_hash_value
		--12c undocumented parameters - "NULL" is a guess
		$IF DBMS_DB_VERSION.VERSION >= 12 $THEN
			,con_name,report_id,dbop_name,dbop_exec_id
		$END
	);


	--TODO: if 
	if not is_report_generated(type, v_clob) then
		dbms_output.put_line('not generated');
	else
		dbms_output.put_line('generated');
	end if;


	--Use Historical if Real-Time is not available.  Real-Time fails for at least two reasons:
	--1: SQL Monitoring results are temporary, and bug 15928155 will cause results to disappear if an operation
	--	takes more than 30 minutes.
	--2: Bugs prevent some queries from being monitored at all.
	--TODO: If active report, what will the clob look like?
	if v_clob is null or v_clob = 'SQL Monitoring Report' then
		/*
			Find last execution interval
			Historical monitoring of the SQL_ID for that interval
			
			report_hist_sql_monitor(p_sql_id, p_start_date, 

		*/


		return 'Could not find SQL Monitoring Report ... TODO';
	else
		return v_clob;
	end if;
end report_sql_monitor;

end;
/
