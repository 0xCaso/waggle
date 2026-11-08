SELECT c.*,
        EXISTS (SELECT 1 FROM revisions r WHERE r.case_id = c.id) AS has_artifact,
        (SELECT r.kind FROM revisions r WHERE r.case_id = c.id ORDER BY r.n DESC LIMIT 1) AS artifact_kind,
        (SELECT r.id FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_id,
        (SELECT r.state FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_state,
        (SELECT r.created_at FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_at,
        (SELECT r.delivered_at FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_delivered_at,
        (SELECT r.applied_at FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_applied_at,
        (SELECT r.not_applied_at FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_not_applied_at,
        (SELECT r.choice FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_choice,
        (SELECT r.choices_json FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_choices_json,
        (SELECT r.answers_json FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_answers_json,
        (SELECT r.message FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_message,
        (SELECT r.intent FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_intent,
        (SELECT r.format FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_format,
        (SELECT r.source FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS latest_reply_source,
        (SELECT ros.seq FROM reply_option_sets ros WHERE ros.reply_id =
           (SELECT r.id FROM replies r WHERE r.case_id = c.id ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1)) AS latest_reply_option_set_seq,
        COALESCE((SELECT o.options_json FROM option_sets o WHERE o.case_id = c.id AND o.seq = 0), c.options_json) AS first_options_json,
        COALESCE((SELECT o.recommendation FROM option_sets o WHERE o.case_id = c.id AND o.seq = 0), c.recommendation) AS first_recommendation,
        (SELECT MAX(o.created_at) FROM option_sets o WHERE o.case_id = c.id AND o.seq > 0) AS options_updated_at,
        COALESCE((SELECT MAX(o.seq) FROM option_sets o WHERE o.case_id = c.id), 0) AS options_seq,
        (SELECT o.question FROM option_sets o WHERE o.case_id = c.id ORDER BY o.seq DESC LIMIT 1) AS options_question,
        (SELECT o.stage_json FROM option_sets o WHERE o.case_id = c.id AND o.stage_json IS NOT NULL ORDER BY o.seq DESC LIMIT 1) AS plan_stage_json,
        (SELECT COUNT(*) FROM option_sets o WHERE o.case_id = c.id AND o.stage_json IS NOT NULL) AS plan_rounds,
        (SELECT rv.kind FROM option_sets o JOIN revisions rv ON rv.case_id = o.case_id AND rv.n = o.revision
           WHERE o.case_id = c.id AND o.own_artifact = 1
             AND o.seq = (SELECT MAX(o2.seq) FROM option_sets o2 WHERE o2.case_id = c.id AND o2.stage_json IS NOT NULL)) AS plan_artifact_kind,
        (SELECT COUNT(DISTINCT r.plan_round) FROM replies r WHERE r.case_id = c.id AND r.plan_round IS NOT NULL
           AND r.intent = 'decision' AND r.state NOT IN ('failed', 'superseded')) AS plan_answered,
        (SELECT MIN(r.created_at) FROM replies r WHERE r.case_id = c.id) AS first_reply_submitted_at,
        (SELECT COUNT(*) FROM messages m WHERE m.case_id = c.id AND m.role = 'agent'
           AND m.created_at > (SELECT MIN(r.created_at) FROM replies r WHERE r.case_id = c.id)) AS update_count,
        (SELECT MAX(m.created_at) FROM messages m WHERE m.case_id = c.id AND m.role = 'agent'
           AND (c.done_at IS NOT NULL OR m.created_at > (SELECT MIN(r.created_at) FROM replies r WHERE r.case_id = c.id))) AS latest_update_at,
        (SELECT substr(m.text, 1, 140) FROM messages m WHERE m.case_id = c.id AND m.role = 'agent'
           AND (c.done_at IS NOT NULL OR m.created_at > (SELECT MIN(r.created_at) FROM replies r WHERE r.case_id = c.id))
           ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1) AS latest_update_message,
        (SELECT COUNT(*) FROM revisions r WHERE r.case_id = c.id AND r.author = 'agent') AS revision_count,
        (SELECT MAX(r.created_at) FROM revisions r WHERE r.case_id = c.id AND r.author = 'agent') AS latest_revision_at,
        (SELECT CASE WHEN s.state = 'disconnected' AND s.last_seen_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-60 seconds') THEN 'live' ELSE s.state END
           FROM sessions s WHERE s.task_id = c.task_id OR s.id = t.owner_session_id ORDER BY s.connected_at DESC LIMIT 1) AS session_state,
        (SELECT s.can_nudge FROM sessions s WHERE s.task_id = c.task_id OR s.id = t.owner_session_id ORDER BY s.connected_at DESC LIMIT 1) AS session_can_nudge,
        (SELECT s.client_name FROM sessions s WHERE s.task_id = c.task_id OR s.id = t.owner_session_id ORDER BY s.connected_at DESC LIMIT 1) AS session_client_name,
        (SELECT CASE WHEN s.state = 'ended'
                  THEN (SELECT MAX(e.at) FROM events e WHERE e.type = 'session.state_changed' AND e.session_id = s.id) END
           FROM sessions s WHERE s.task_id = c.task_id OR s.id = t.owner_session_id ORDER BY s.connected_at DESC LIMIT 1) AS session_ended_at,
        t.name AS task_name,
        t.project AS project,
        t.linear_key AS linear_key
      FROM cases c
      JOIN tasks t ON t.id = c.task_id
