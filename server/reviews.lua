FinanceReviews = {}

local function playerIdentifier(source)
    local esx = FinanceCore.getESX()
    if not esx then return 'system' end
    local xPlayer = esx.GetPlayerFromId(source)
    return xPlayer and xPlayer.getIdentifier and xPlayer.getIdentifier() or 'system'
end

local function normalizeSourceRef(sourceType, sourceId, sourceKey)
    local normalizedId = sourceId
    local normalizedKey = sourceKey

    if sourceType == Config.RecordTypes.business then
        if (normalizedKey == nil or normalizedKey == '') and normalizedId ~= nil then
            normalizedKey = tostring(normalizedId)
        end
        normalizedId = nil
    elseif type(normalizedId) == 'string' then
        local asNumber = tonumber(normalizedId)
        if asNumber then
            normalizedId = asNumber
        else
            if normalizedKey == nil or normalizedKey == '' then
                normalizedKey = normalizedId
            end
            normalizedId = nil
        end
    end

    if normalizedKey ~= nil and normalizedKey ~= '' then
        normalizedKey = tostring(normalizedKey)
    end

    return normalizedId, normalizedKey
end

function FinanceReviews.ensureReview(sourceType, sourceId, sourceKey)
    local refId, refKey = normalizeSourceRef(sourceType, sourceId, sourceKey)
    local review = FinanceDB.fetchReviewBySource(sourceType, refId, refKey)
    if review then
        return review.id
    end

    return MySQL.insert.await('INSERT INTO doj_finance_reviews (source_type, source_id, source_key, status) VALUES (?, ?, ?, ?)', {
        sourceType,
        refId,
        refKey,
        'neu'
    })
end

function FinanceReviews.addAudit(sourceType, sourceId, sourceKey, action, actor, payload)
    local refId, refKey = normalizeSourceRef(sourceType, sourceId, sourceKey)
    MySQL.insert.await('INSERT INTO doj_finance_auditlog (source_type, source_id, source_key, action, actor_identifier, payload) VALUES (?, ?, ?, ?, ?, ?)', {
        sourceType,
        refId,
        refKey,
        action,
        actor,
        json.encode(payload or {})
    })
end

function FinanceReviews.setStatus(source, payload)
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, refId, refKey)
    MySQL.update.await('UPDATE doj_finance_reviews SET status = ?, assigned_to = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?', {
        payload.status,
        payload.assigned_to,
        reviewId
    })

    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'status_changed', playerIdentifier(source), {
        status = payload.status,
        assigned_to = payload.assigned_to
    })

    FinanceDB.invalidateCache('dashboard:')
    return true
end

function FinanceReviews.addNote(source, payload)
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, refId, refKey)
    local id = MySQL.insert.await('INSERT INTO doj_finance_notes (review_id, source_type, source_id, source_key, author_identifier, note, is_internal) VALUES (?, ?, ?, ?, ?, ?, ?)', {
        reviewId,
        payload.source_type,
        refId,
        refKey,
        playerIdentifier(source),
        payload.note,
        payload.is_internal and 1 or 0
    })

    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'note_added', playerIdentifier(source), {
        note_id = id
    })

    return id
end

function FinanceReviews.getCaseBundle(sourceType, sourceId, sourceKey)
    local refId, refKey = normalizeSourceRef(sourceType, sourceId, sourceKey)
    local bundle = FinanceDB.fetchReviewBundle(sourceType, refId, refKey)
    local deadline = FinanceDB.fetchDeadline(sourceType, refId, refKey)
    local links = FinanceDB.fetchLinks(sourceType, refId, refKey)

    return {
        review = bundle.review,
        notes = bundle.notes,
        audit = bundle.audit,
        deadline = deadline,
        links = links
    }
end

function FinanceReviews.setDeadline(source, payload)
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    FinanceDB.upsertDeadline(payload.source_type, refId, refKey, payload.due_date, payload.reason, playerIdentifier(source))
    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'deadline_override', playerIdentifier(source), {
        due_date = payload.due_date,
        reason = payload.reason
    })
    return true
end

function FinanceReviews.removeDeadline(source, payload)
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    FinanceDB.deleteDeadline(payload.source_type, refId, refKey)
    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'deadline_removed', playerIdentifier(source), {})
    return true
end

function FinanceReviews.addLink(source, payload)
    local refId, refKey = normalizeSourceRef(payload.tax_source_type, payload.tax_source_id, payload.tax_source_key)
    local id = FinanceDB.createLink({
        business_job = payload.business_job,
        period = payload.period,
        transaction_id = payload.transaction_id,
        tax_source_type = payload.tax_source_type,
        tax_source_id = refId,
        tax_source_key = refKey,
        match_quality = payload.match_quality,
        comment = payload.comment,
        created_by = playerIdentifier(source),
        link_type = payload.link_type,
        source_table = payload.source_table,
        source_ref = payload.source_ref,
        target_type = payload.target_type,
        target_ref = payload.target_ref,
        confidence_score = payload.confidence_score,
        confidence_band = payload.confidence_band,
        reason_codes = payload.reason_codes,
        reason_text = payload.reason_text,
        detection_mode = payload.detection_mode,
        review_status = payload.review_status
    })

    FinanceReviews.addAudit(payload.tax_source_type, refId, refKey, 'link_added', playerIdentifier(source), {
        link_id = id,
        transaction_id = payload.transaction_id
    })

    return id
end

function FinanceReviews.reviewLink(source, payload)
    local ok = FinanceDB.setLinkReviewStatus(payload.link_id, payload.review_status, payload.reason_code, payload.note, playerIdentifier(source))
    if not ok then return false end
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'link_reviewed', playerIdentifier(source), {
        link_id = payload.link_id,
        review_status = payload.review_status,
        reason_code = payload.reason_code
    })
    return true
end

function FinanceReviews.removeLink(source, payload)
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    FinanceDB.deleteLink(payload.link_id)
    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'link_removed', playerIdentifier(source), {
        link_id = payload.link_id
    })
    return true
end

function FinanceReviews.setCaseMeta(source, payload)
    local refId, refKey = normalizeSourceRef(payload.source_type, payload.source_id, payload.source_key)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, refId, refKey)

    FinanceDB.updateReviewMeta(reviewId, {
        priority = payload.priority,
        evidence = payload.evidence,
        doj_case_id = payload.doj_case_id,
        follow_up_at = payload.follow_up_at,
        assigned_to = payload.assigned_to
    })

    if payload.doj_case_id or payload.doj_case_number then
        FinanceDB.upsertCaseLink(reviewId, payload.doj_case_id, payload.doj_case_number, payload.link_type or 'related', playerIdentifier(source))
    end

    FinanceReviews.addAudit(payload.source_type, refId, refKey, 'case_meta_updated', playerIdentifier(source), {
        priority = payload.priority,
        doj_case_id = payload.doj_case_id,
        follow_up_at = payload.follow_up_at
    })

    return true
end
