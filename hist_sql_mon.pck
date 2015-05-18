create or replace package hist_sql_mon authid current_user is
--Copyright (C) 2015 Jon Heller.  This program is licensed under the LGPLv3.

C_VERSION constant varchar2(100) := '1.2.0';

/*
Purpose: Extend Real-Time SQL Monitoring to Historical SQL Monitoring.  Uses AWR information
	to recreate results similar to REPORT_SQL_MONITOR.

Parameters:
	sql_id - SQL_ID to monitor.
	p_start_time_filter, p_end_time_filter - Period of time to monitor.
*/
function hist_sql_mon(
	p_sql_id                    IN VARCHAR2,
	p_start_time_filter         IN DATE      DEFAULT  NULL,
	p_end_time_filter           IN DATE      DEFAULT  NULL
	)
return clob;

/*
TODO: Does not work yet.

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
*/

end hist_sql_mon;
/
create or replace package body hist_sql_mon is

--Session state to avoid checking privileges if they were already met.
g_hist_sql_mon_privs_met boolean := false;


--What is the source of the request?  This is useful for printing messages.
C_SOURCE_DIRECT constant varchar2(100) := 'Results were directly requested from user.';
C_SOURCE_DONE_ERROR constant varchar2(100) := 'REPORT_SQL_MONITOR finished with Done (Error).';
C_SOURCE_NO_RESULTS constant varchar2(100) := 'REPORT_SQL_MONITOR did not display any results.';

C_HIST_SQL_MON_SQL constant varchar2(32767) :=
substr(q'<
----------------------------------
--Historical SQL Monitoring Report
----------------------------------
--Execution plans and ASH data, where there is at least some samples for a plan_hash_value.
select
	--Add execution metadata.
	case
		when plan_table_output like 'Plan hash value: %' then
			plan_table_output||chr(10)||
			'Start Time     : '||to_char(min_sample_time, 'YYYY-MM-DD HH24:MI:SS')||chr(10)||
			'End Time       : '||to_char(max_sample_time, 'YYYY-MM-DD HH24:MI:SS')||chr(10)||
			--Add note about where the data came from.
			case
				when has_active_data = 1 and has_historical_data = 1 then
					'Source         : Data came from both GV$ACTIVE_SESSION_HISTORY and DBA_HIST_ACTIVE_SESS_HISTORY.  Counts from GV$ACTIVE_SESSION_HISTORY are divided by 10 to match sampling frequency of historical data.'
				when has_active_data = 1 and has_historical_data = 0 then
					'Source         : Data came from GV$ACTIVE_SESSION_HISTORY only.  Counts from GV$ACTIVE_SESSION_HISTORY are divided by 10 to match sampling frequency of historical data.'
				when has_active_data = 0 and has_historical_data = 1 then
					'Source         : Data came from DBA_HIST_ACTIVE_SESS_HISTORY only.'
			end
		when plan_table_output like '|%' then
			rpad(plan_table_output, max_output_length - 1, ' ') || '|'
		when plan_table_output like lpad('-', 60, '-')||'%' then
			rpad(plan_table_output, max_output_length, '=')
		else
			plan_table_output
	end plan_table_output
from
(
	--Execution plans and ASH data.
	select
		plan_table_output
			||
			case
				when plan_table_output like '| Id  |%' then ' '||trim('Activity (%) | Activity Detail (# samples|# distinct samples) ')
				when ash_string is not null then ' '||ash_string
				when plan_table_output like '|%' and ash_string is null then '              |'
			end plan_table_output
		--Determine the maximum line length, for creating a text box.
		,max(nvl(length(
			case when plan_table_output like '|%' then
				plan_table_output
					||
					case
						when plan_table_output like '| Id  |%' then ' '||trim('Activity (%) | Activity Detail (# samples|# distinct samples) ')
						when ash_string is not null then ' '||ash_string
						when plan_table_output like '|%' and ash_string is null then '              |'
					end
			else null end
		), 0)) over (partition by execution_plans.plan_hash_value) + 1 max_output_length
		,count(ash_string) over (partition by execution_plans.plan_hash_value) count_per_hash
		,execution_plans.plan_hash_value, execution_plans.rownumber
		,min(min_sample_time) over (partition by execution_plans.plan_hash_value) min_sample_time
		,max(max_sample_time) over (partition by execution_plans.plan_hash_value) max_sample_time
		,max(has_active_data) over (partition by execution_plans.plan_hash_value) has_active_data
		,max(has_historical_data) over (partition by execution_plans.plan_hash_value) has_historical_data
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
			,has_active_data, has_historical_data
			,'     '||max(count_percent)||' | '||
			listagg(event||' ('||sample_count||'|'||sample_distinct_count||trim(') '), ', ')
				within group (order by sample_count desc) ash_string
		from
		(
			--ASH summary with percentages.
			select active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, min_sample_time, max_sample_time, has_active_data, has_historical_data, event
				,to_char(ratio_to_report(sample_count) over (partition by sql_plan_hash_value) * 100, '999.00') count_percent
				,sample_count, sample_distinct_count
			from
			(
				--ASH summary.
				select active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, min_sample_time, max_sample_time, has_active_data, has_historical_data, event
					--Divide active data by 10 since it is sampled 10 times more than historical data.
					,case when active_1_historical_2 = 1 then ceil(count(*) / 10) else count(*) end sample_count
					,case when active_1_historical_2 = 1 then ceil(count(distinct sample_time) / 10) else count(distinct sample_time) end sample_distinct_count
				from
				(
					--ASH raw data with min and max sample times.
					select active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, event, sample_time,
						min(sample_time) over (partition by sql_plan_hash_value, sql_plan_line_id) min_sample_time,
						max(sample_time) over (partition by sql_plan_hash_value, sql_plan_line_id) max_sample_time,
						max(case when active_1_historical_2 = 1 then 1 else 0 end) over (partition by sql_plan_hash_value, sql_plan_line_id) has_active_data,
						max(case when active_1_historical_2 = 2 then 1 else 0 end) over (partition by sql_plan_hash_value, sql_plan_line_id) has_historical_data
					from
					(
						--ASH raw data.
						select 1 active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, nvl(event, 'Cpu') event, sample_time
						from gv$active_session_history
						where sql_id = :p_sql_id
							and :uses_v$ash = 1
							and sample_time between :start_date and :end_date
							--Exclude data that will be in DBA_HIST.
							and sample_time > :max_snap_date
						union all
						select 2 active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, nvl(event, 'Cpu') event, sample_time
						from dba_hist_active_sess_history
						where sql_id = :p_sql_id
							--Enable partition pruning.
							--Note that DBA_HIST_* tables do not always have matching SNAP_IDs.
							--If this table has data that's not in DBA_HIST_SNAPSHOT it will be excluded here.
							and dbid = :dbid
							and snap_id between :start_snap_id and :end_snap_id
							and sample_time between :start_date and :end_date
					) ash_raw_data
				) ash_raw_min_max_sample_time
				group by active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, min_sample_time, max_sample_time, has_active_data, has_historical_data, event
				order by active_1_historical_2, sql_plan_hash_value, sql_plan_line_id, count(*)
			) ash_summary
		) ash_summary_with_percentages
		group by sql_plan_hash_value, sql_plan_line_id, min_sample_time, max_sample_time, has_active_data, has_historical_data
	) ash_data
		on execution_plans.plan_hash_value = ash_data.sql_plan_hash_value
		and execution_plans.sql_plan_line_id = ash_data.sql_plan_line_id
	order by execution_plans.plan_hash_value, execution_plans.rownumber
) execution_plans_and_ash_data
where count_per_hash > 0
order by plan_hash_value, rownumber
>', 2);



------------------------------------------------------------------------------------------------------------------------
--Purpose: Raise exception if diagnostic and tuning packs are not licensed.
procedure check_diag_and_tuning_license is
	v_license varchar2(4000);
begin
	execute immediate q'<select value from v$parameter where name = 'control_management_pack_access'>'
	into v_license ;

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
	execute immediate q'<select value from v$parameter where name = 'control_management_pack_access'>'
	into v_license;

	if v_license not in ('DIAGNOSTIC+TUNING', 'DIAGNOSTIC') then
		raise_application_error(-20000, 'This procedure requires the diagnostic pack.  The parameter '||
			'control_management_pack_access must be set to ''DIAGNOSTIC+TUNING'' or ''DIAGNOSTIC'', the '||
			'current value is '||v_license||'.');
	end if;
end check_diag_license;


------------------------------------------------------------------------------------------------------------------------
--Purpose: Check for privileges needed for HIST_SQL_MON and throw a helpful error message if any are missing.
--	There is no equivalant for REPORT_SQL_MONITOR because I do not know exactly what that package requires.
procedure check_hist_sql_mon_privs is
	v_table_does_not_exist exception;
	pragma exception_init(v_table_does_not_exist, -00942);

	v_tables sys.odcivarchar2list := sys.odcivarchar2list(
		'v$parameter',
		'dba_hist_snapshot',
		'v$database',
		'dba_hist_sqltext',
		'gv$active_session_history',
		'dba_hist_active_sess_history',
		'sys.gv_$sql'
	);
	v_missing_privs varchar2(32767);
begin
	--Do not check if privileges were already met once.
	if not g_hist_sql_mon_privs_met then
		--Check for access to each table.
		for i in 1 .. v_tables.count loop
			begin
				execute immediate 'select 1 from '||v_tables(i)||' where rownum = 0';
			exception when v_table_does_not_exist then
				v_missing_privs := v_missing_privs || ', '||v_tables(i);
			end;
		end loop;

		--Raise error if any were missing.
		if v_missing_privs is not null then
			raise_application_error(-20000, 'Cannot run hist_sql_mon.hist_sql_mon().  '||
				sys_context('userenv', 'session_user')||' is missing SELECT privileges on '||
				'these tables: '||substr(v_missing_privs, 2)||'.'||chr(10)||
				'There are at least three ways to solve this:'||chr(10)||
				'1. GRANT SELECT ANY DATA DICTIONARY TO '||sys_context('userenv', 'session_user')||';'||chr(10)||
				'2. GRANT SELECT_CATALOG_ROLE TO '||sys_context('userenv', 'session_user')||';'||chr(10)||
				'3. Grant select on tables listed above to '||sys_context('userenv', 'session_user')||'.'
			);
		--Set flag and do nothing if nothing is missing.
		else
			g_hist_sql_mon_privs_met := true;
		end if;
	end if;
end check_hist_sql_mon_privs;


------------------------------------------------------------------------------------------------------------------------
--Purpose: Convert start and end dates to start and stop SNAP_IDs, and a flag for whether or not to use v$ASH view.
procedure get_time_values(
	p_start_time_filter  in  date,
	p_end_time_filter    in  date,
	p_out_dbid           out number,
	p_out_start_snap_id  out number,
	p_out_start_date     out date,
	p_out_end_snap_id    out number,
	p_out_end_date       out date,
	p_out_uses_v$ash     out number,
	p_out_max_snap_date  out date,
	p_out_warning        out varchar2
) is
	v_min_snap_id number;
	v_min_snap_date date;
	v_max_snap_id number;
begin
	--Get DBID.
	execute immediate q'<
		select dbid
		from v$database
	>'
	into p_out_dbid;

	--Get min and max snapshot data.
	execute immediate q'<
		select min(snap_id), min(begin_interval_time), max(snap_id), max(end_interval_time)
		from dba_hist_snapshot
		where dbid = (select dbid from v$database)
	>'
	into v_min_snap_id, v_min_snap_date, v_max_snap_id, p_out_max_snap_date;

	--Error if input start date is after current date.
	if p_start_time_filter >= sysdate then
		raise_application_error(-20000, 'Start date must be in the past.');
	end if;

	--Error if input start date is on or after input end date.
	if p_start_time_filter >= p_end_time_filter then
		raise_application_error(-20000, 'Start date must be earlier than end date.');
	end if;

	--Error if input end date before first snapshot interval.
	if p_end_time_filter <= v_min_snap_date then
		declare
			v_retention varchar2(4000);
		begin
			--Get current retention period.
			execute immediate q'<
				select to_char(retention)
				from dba_hist_wr_control
				where dbid = (select dbid from v$database)
			>'
			into v_retention;

			--Display error.
			raise_application_error(-20000, 'The end date, '||to_char(p_end_time_filter, 'YYYY-MM-DD HH24:MI:SS')||
				', is before the start of the earliest snapshot, '||to_char(v_min_snap_date, 'YYYY-MM-DD HH24:MI:SS')||
				'.  The current retention is '||v_retention||'.  Use DBMS_WORKLOAD_REPOSITORY to increase retention, '||
				'but that will only help in the future.');
		end;
	end if;

	--Find start snap and date.
	if p_start_time_filter is null then
		p_out_start_snap_id := v_min_snap_id;
		p_out_start_date := v_min_snap_date;
	elsif p_start_time_filter <= v_min_snap_date then
		p_out_start_snap_id := v_min_snap_id;
		p_out_start_date := v_min_snap_date;
		p_out_warning := 'Start date is before the earliest snapshot, some data may be missing.';
	else
		--Get snap and date.
		execute immediate q'<
			--Get first interval on or before time.  Not `between` begin and end interval - there may be missing snapshots.
			select max(snap_id) keep (dense_rank last order by begin_interval_time), :p_start_time_filter
			from dba_hist_snapshot
			where dbid = (select dbid from v$database)
				and :p_start_time_filter >= begin_interval_time
		>'
		into p_out_start_snap_id, p_out_start_date
		using p_start_time_filter, p_start_time_filter;
	end if;

	--Find end snap and date.
	if p_end_time_filter is null or p_end_time_filter >= p_out_max_snap_date then
		p_out_end_snap_id := v_max_snap_id;
		p_out_end_date := sysdate;
		p_out_uses_v$ash := 1;
	else
		--Get snap and date.
		execute immediate q'<
			--Get first interval on or after time.  Not `between` begin and end interval - there may be missing snapshots.
			select min(snap_id) keep (dense_rank first order by begin_interval_time), :p_end_time_filter
			from dba_hist_snapshot
			where dbid = (select dbid from v$database)
				and :p_end_time_filter <= end_interval_time
		>'
		into p_out_end_snap_id, p_out_end_date
		using p_end_time_filter, p_end_time_filter;

		p_out_uses_v$ash := 0;
	end if;
end get_time_values;


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
	,p_source in varchar2, p_time_range_warning in varchar2)
return clob is
	v_header clob;
	v_reason varchar2(100);
	v_sql_text_first_100_char varchar2(100);
begin
	--Title
	v_header := 'Historical SQL Monitoring '||C_VERSION||' (when Real-Time SQL Monitoring does not work)'||chr(10)||chr(10);

	--SQL Text.  Replace new-lines so that text is all on one line.
	begin
		execute immediate q'<
			select coalesce(
				(
					select to_char(regexp_replace(replace(substr(sql_text, 1, 100), chr(10), null), '\s+', ' '))
					from dba_hist_sqltext
					where sql_id = :p_sql_id
				),
				(
					select distinct to_char(regexp_replace(replace(substr(sql_text, 1, 100), chr(10), null), '\s+', ' '))
					from gv$sql
					where sql_id = :p_sql_id
				)
			)
			from dual
		>'
		into v_sql_text_first_100_char
		using p_sql_id, p_sql_id;
	exception when no_data_found then
		raise_application_error(-20000, 'asdf');
	end;

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
		--TODO - add this after REPORT_SQL_MONITOR support is added.
		--' Reason Called       : '||v_reason||chr(10)||
		' Report Created Date : '||to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS')||chr(10)||
		' Report Created by   : '||user||chr(10)||
		' SQL_ID              : '||p_sql_id||chr(10)||
		' SQL_TEXT            : '||v_sql_text_first_100_char||chr(10)||
		' P_START_TIME_FILTER : '||nvl(to_char(p_start_time_filter, 'YYYY-MM-DD HH24:MI:SS'), 'NULL')||chr(10)||
		' P_END_TIME_FILTER   : '||nvl(to_char(p_end_time_filter, 'YYYY-MM-DD HH24:MI:SS'), 'NULL')||chr(10);

	--Add warnings about dates being outside of AWR range.
	if p_time_range_warning is not null then
		v_header := v_header||' WARNING             : '||p_time_range_warning||chr(10);
	end if;

	v_header := v_header||chr(10)||chr(10);

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

	v_dbid number;
	v_start_snap_id number;
	v_start_date date;
	v_end_snap_id number;
	v_end_date date;
	v_uses_v$ash number;
	v_max_snap_date date;
	v_warning varchar2(4000);
begin
	--Check privileges and license.
	check_hist_sql_mon_privs;
	check_diag_license;

	--Find time period.
	get_time_values(p_start_time_filter,p_end_time_filter,v_dbid,v_start_snap_id,
		v_start_date,v_end_snap_id,v_end_date,v_uses_v$ash,v_max_snap_date,v_warning);

	--Get header.
	v_output_clob := get_hist_sql_mon_header(p_sql_id, p_start_time_filter, p_end_time_filter, p_source, v_warning);

	--Execute statement.
	execute immediate C_HIST_SQL_MON_SQL
	bulk collect into v_output_lines
	using p_sql_id, p_sql_id, p_sql_id, v_uses_v$ash, v_start_date, v_end_date, v_max_snap_date, p_sql_id, v_dbid
		,v_start_snap_id, v_end_snap_id, v_start_date, v_end_date;

	--Print it out for debugging.
	--Since some tools have 4K limit, split it up around first linefeed after 3800.
	v_sql := replace(replace(replace(replace(replace(replace(replace(replace(
			C_HIST_SQL_MON_SQL, ':p_sql_id', ''''||p_sql_id||'''')
		, ':uses_v$ash', '/*uses_v$ash*/'||v_uses_v$ash)
		,':start_snap_id', v_start_snap_id)
		,':end_snap_id', v_end_snap_id)
		,':max_snap_date', 'timestamp '''||to_char(v_max_snap_date, 'YYYY-MM-DD HH24:MI:SS')||'''')
		,':start_date', 'timestamp '''||to_char(v_start_date, 'YYYY-MM-DD HH24:MI:SS')||'''')
		,':end_date', 'timestamp '''||to_char(v_end_date, 'YYYY-MM-DD HH24:MI:SS')||'''')
		,':dbid', to_char(v_dbid));
	dbms_output.enable(1000000);
	dbms_output.put_line(substr(v_sql, 1, instr(v_sql, chr(10), 3800)-1));
	dbms_output.put_line(substr(v_sql, instr(v_sql, chr(10), 3800)+1));

	--Convert lines to CLOB.
	for i in 1 .. v_output_lines.count loop
		v_output_clob := v_output_clob || v_output_lines(i) || chr(10);
	end loop;

	--If there were no lines, print message.
	if v_output_lines.count = 0 then
		v_output_clob := v_output_clob || 'No data found.';
	end if;

	return v_output_clob;

exception when no_data_found then
	raise_application_error(-20000, 'Re-raising NO_DATA_FOUND error because they are suppressed in SELECT statements.'||
		chr(10)||dbms_utility.format_error_stack||dbms_utility.format_error_backtrace);
end hist_sql_mon;


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
TODO: Not implemented yet

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

	--Use Historical if Real-Time is not available.  Real-Time fails for at least two reasons:
	--1: SQL Monitoring results are temporary, and bug 15928155 will cause results to disappear if an operation
	--	takes more than 30 minutes.
	--2: Bugs prevent some queries from being monitored at all.

	--TODO: Need to distinguish between no results vs. broken results.
	if not is_report_generated(type, v_clob) then
		dbms_output.put_line('not generated');
	else
		dbms_output.put_line('generated');
	end if;

	if v_clob is null or v_clob = 'SQL Monitoring Report' then
		--Find last execution interval
		--Historical monitoring of the SQL_ID for that interval
		--report_hist_sql_monitor(p_sql_id, p_start_date,
		return 'Could not find SQL Monitoring Report ... TODO';
	else
		return v_clob;
	end if;

exception when no_data_found then
	raise_application_error(-20000, 'Re-raising NO_DATA_FOUND error because they are suppressed in SELECT statements.'||
		chr(10)||dbms_utility.format_error_stack||dbms_utility.format_error_backtrace);
end report_sql_monitor;

end hist_sql_mon;
/
