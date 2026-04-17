FinanceReviews = {}

local function playerIdentifier(source)
    local esx = FinanceCore.getESX()
    if not esx then return 'system' end
    local xPlayer = esx.GetPlayerFromId(source)
    return xPlayer and xPlayer.getIdentifier and xPlayer.getIdentifier() or 'system'
end

function FinanceReviews.ensureReview(sourceType, sourceId, sourceKey)
    local review = FinanceDB.fetchReviewBySource(sourceType, sourceId, sourceKey)
    if review then
        return review.id
    end

    return MySQL.insert.await('INSERT INTO doj_finance_reviews (source_type, source_id, source_key, status) VALUES (?, ?, ?, ?)', {
        sourceType,
        sourceId,
        sourceKey,
        'neu'
    })
end

function FinanceReviews.addAudit(sourceType, sourceId, sourceKey, action, actor, payload)
    MySQL.insert.await('INSERT INTO doj_finance_auditlog (source_type, source_id, source_key, action, actor_identifier, payload) VALUES (?, ?, ?, ?, ?, ?)', {
        sourceType,
        sourceId,
        sourceKey,
        action,
        actor,
        json.encode(payload or {})
    })
end

function FinanceReviews.setStatus(source, payload)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, payload.source_id, payload.source_key)
    MySQL.update.await('UPDATE doj_finance_reviews SET status = ?, assigned_to = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?', {
        payload.status,
        payload.assigned_to,
        reviewId
    })

    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'status_changed', playerIdentifier(source), {
        status = payload.status,
        assigned_to = payload.assigned_to
    })

    FinanceDB.invalidateCache('dashboard:')
    return true
end

function FinanceReviews.addNote(source, payload)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, payload.source_id, payload.source_key)
    local id = MySQL.insert.await('INSERT INTO doj_finance_notes (review_id, source_type, source_id, source_key, author_identifier, note, is_internal) VALUES (?, ?, ?, ?, ?, ?, ?)', {
        reviewId,
        payload.source_type,
        payload.source_id,
        payload.source_key,
        playerIdentifier(source),
        payload.note,
        payload.is_internal and 1 or 0
    })

    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'note_added', playerIdentifier(source), {
        note_id = id
    })

    return id
end

function FinanceReviews.getCaseBundle(sourceType, sourceId, sourceKey)
    local bundle = FinanceDB.fetchReviewBundle(sourceType, sourceId, sourceKey)
    local deadline = FinanceDB.fetchDeadline(sourceType, sourceId, sourceKey)
    local links = FinanceDB.fetchLinks(sourceType, sourceId, sourceKey)

    return {
        review = bundle.review,
        notes = bundle.notes,
        audit = bundle.audit,
        deadline = deadline,
        links = links
    }
end

function FinanceReviews.setDeadline(source, payload)
    FinanceDB.upsertDeadline(payload.source_type, payload.source_id, payload.source_key, payload.due_date, payload.reason, playerIdentifier(source))
    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'deadline_override', playerIdentifier(source), {
        due_date = payload.due_date,
        reason = payload.reason
    })
    return true
end

function FinanceReviews.removeDeadline(source, payload)
    FinanceDB.deleteDeadline(payload.source_type, payload.source_id, payload.source_key)
    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'deadline_removed', playerIdentifier(source), {})
    return true
end

function FinanceReviews.addLink(source, payload)
    local id = FinanceDB.createLink({
        business_job = payload.business_job,
        period = payload.period,
        transaction_id = payload.transaction_id,
        tax_source_type = payload.tax_source_type,
        tax_source_id = payload.tax_source_id,
        tax_source_key = payload.tax_source_key,
        match_quality = payload.match_quality,
        comment = payload.comment,
        created_by = playerIdentifier(source)
    })

    FinanceReviews.addAudit(payload.tax_source_type, payload.tax_source_id, payload.tax_source_key, 'link_added', playerIdentifier(source), {
        link_id = id,
        transaction_id = payload.transaction_id
    })

    return id
end

function FinanceReviews.removeLink(source, payload)
    FinanceDB.deleteLink(payload.link_id)
    FinanceReviews.addAudit(payload.source_type, payload.source_id, payload.source_key, 'link_removed', playerIdentifier(source), {
        link_id = payload.link_id
    })
    return true
end
