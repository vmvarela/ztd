-- Exceptions belong to the plan they explain, not a separate workflow.
INSERT INTO legacy_records(source,entity_type,entity_id,payload_json,disposition,reason)
SELECT 'schema-13','limit_override',id,json_object('id',id,'actor_id',actor_id,'local_date',local_date,'rule',rule,'reason',reason,'created_by',created_by,'created_at',created_at),'imported','plan exception replaces override records' FROM daily_limit_overrides;
UPDATE plans SET exception_reason = coalesce((SELECT reason FROM daily_limit_overrides WHERE rule='mit' AND local_date=plans.period ORDER BY created_at DESC LIMIT 1),'') WHERE kind='daily';
DROP TABLE daily_limit_overrides;
INSERT INTO legacy_records(source,entity_type,entity_id,scope_id,payload_json,disposition,reason)
SELECT 'schema-13','subgoal',id,scope_id,json_object('id',id,'statement',statement,'start_on',start_on,'end_on',end_on,'status',status,'created_at',created_at,'updated_at',updated_at),'imported','historical subgoal; use projects for new steps' FROM goals WHERE kind='subgoal';
DELETE FROM goals WHERE kind='subgoal';
