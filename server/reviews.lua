FinanceReviews = {}

local function getIdentifier(xPlayer)
    return xPlayer and xPlayer.getIdentifier and xPlayer.getIdentifier() or 'system'
end

function FinanceReviews.ensureReview(sourceType, sourceId, sourceKey)
    local existing = MySQL.single.await([[SELECT id FROM doj_finance_reviews WHERE source_type = ? AND source_id <=> ? AND source_key <=> ?]], {
        sourceType,
        sourceId,
        sourceKey
    })

    if existing then
        return existing.id
    end

    local insertId = MySQL.insert.await([[INSERT INTO doj_finance_reviews (source_type, source_id, source_key, status) VALUES (?, ?, ?, 'neu')]], {
        sourceType,
        sourceId,
        sourceKey
    })

    FinanceDB.invalidateCache('dashboard:')
    return insertId
end

function FinanceReviews.logAudit(sourceType, sourceId, sourceKey, action, actorIdentifier, payload)
    MySQL.insert.await([[INSERT INTO doj_finance_auditlog (source_type, source_id, source_key, action, actor_identifier, payload) VALUES (?, ?, ?, ?, ?, ?)]], {
        sourceType,
        sourceId,
        sourceKey,
        action,
        actorIdentifier,
        json.encode(payload or {})
    })
end

function FinanceReviews.setStatus(xPlayer, payload)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, payload.source_id, payload.source_key)
    MySQL.update.await([[UPDATE doj_finance_reviews SET status = ?, assigned_to = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?]], {
        payload.status,
        payload.assigned_to,
        reviewId
    })

    FinanceReviews.logAudit(payload.source_type, payload.source_id, payload.source_key, 'status_changed', getIdentifier(xPlayer), {
        status = payload.status,
        assigned_to = payload.assigned_to
    })

    return true
end

function FinanceReviews.addNote(xPlayer, payload)
    local reviewId = FinanceReviews.ensureReview(payload.source_type, payload.source_id, payload.source_key)
    local noteId = MySQL.insert.await([[INSERT INTO doj_finance_notes (review_id, source_type, source_id, source_key, author_identifier, note, is_internal) VALUES (?, ?, ?, ?, ?, ?, ?)]], {
        reviewId,
        payload.source_type,
        payload.source_id,
        payload.source_key,
        getIdentifier(xPlayer),
        payload.note,
        payload.is_internal and 1 or 0
    })

    FinanceReviews.logAudit(payload.source_type, payload.source_id, payload.source_key, 'note_added', getIdentifier(xPlayer), {
        note_id = noteId
    })

    return noteId
end

function FinanceReviews.getReviewBundle(sourceType, sourceId, sourceKey)
    local review = MySQL.single.await([[SELECT id, status, assigned_to, updated_at, created_at FROM doj_finance_reviews WHERE source_type = ? AND source_id <=> ? AND source_key <=> ?]], {
        sourceType,
        sourceId,
        sourceKey
    })

    if not review then
        return {
            review = nil,
            notes = {},
            audit = {}
        }
    end

    local notes = MySQL.query.await([[SELECT id, author_identifier, note, is_internal, created_at FROM doj_finance_notes WHERE review_id = ? ORDER BY id DESC]], {
        review.id
    }) or {}

    local audit = MySQL.query.await([[SELECT id, action, actor_identifier, payload, created_at FROM doj_finance_auditlog WHERE source_type = ? AND source_id <=> ? AND source_key <=> ? ORDER BY id DESC LIMIT 50]], {
        sourceType,
        sourceId,
        sourceKey
    }) or {}

    return {
        review = review,
        notes = notes,
        audit = audit
    }
end
