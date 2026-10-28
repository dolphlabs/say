# Resolution and Settlement API Specification

This document details the HTTP API for Prompt 08: **Resolution and Settlement** in **say**.

---

## 1. Authentication and Authorization Roles

- **Public**: Anyone (or authenticated players for disputes).
- **Resolver**: Users holding the `resolver` role or `super_admin` role.
- **Super Admin**: Users holding the `super_admin` role. Required for final decisions, dispute adjudication, and void approval.

---

## 2. Public & Player Endpoints

### 2.1 Public Resolution Card
- **Endpoint**: `GET /v1/markets/:market_id/resolution`
- **Auth**: None (Public)
- **Response**: `200 OK`
```json
{
  "state": "PROPOSED",
  "proposed_outcome": "YES",
  "dispute_until": "2026-10-28T18:30:00Z",
  "evidence": [
    {
      "source": "sports.example.com",
      "finding": "Remo Stars 2 - 1 Sporting Lagos (FT)",
      "verdict": "SAYS_YES",
      "retrieved_at": "2026-10-28T18:00:00Z",
      "snapshot_url": "https://sports.example.com/match/remo-stars-vs-sporting-lagos",
      "sha256": "4b227777d4dd1fc61c6f884f48641d02b4d121d3fd328cb08b5531fcacdabf8a"
    }
  ],
  "final": {
    "outcome": "YES",
    "reason": "Official league match report confirmed scoreline.",
    "decided_at": "2026-10-28T18:35:00Z"
  }
}
```

### 2.2 File a Dispute
- **Endpoint**: `POST /v1/markets/:market_id/dispute`
- **Auth**: Authenticated Player (`say_session` cookie)
- **Rules**:
  - Account must hold or have held a position in the market.
  - Account may file at most 1 dispute per market.
  - Can only file while state is `PROPOSED` and dispute window is open (`now() < dispute_until`).
  - Reason must be between 20 and 1,000 characters.
- **Request Body**:
```json
{
  "reason": "The referee disallowed the second goal on VAR review after the final whistle.",
  "link_url": "https://league.example.com/official-corrections/1029"
}
```
- **Response**: `200 OK`
```json
{
  "dispute_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"
}
```
- **Error Codes**:
  - `400 INVALID_REASON_LENGTH`: Reason shorter than 20 chars or longer than 1,000 chars.
  - `400 ALREADY_DISPUTED`: Account already submitted a dispute for this market.
  - `403 NOT_ELIGIBLE_TO_DISPUTE`: Account never held shares or contracts in this market.
  - `400 WINDOW_OPEN`: Dispute window closed.
  - `400 INVALID_STATE`: Market is not in `PROPOSED` state.

---

## 3. Admin & Resolver Endpoints

### 3.1 Resolution Queue
- **Endpoint**: `GET /v1/admin/resolution/queue?state={COLLECTING|PROPOSED|AWAITING_FINAL|HELD|OVERDUE}`
- **Auth**: `resolver` or `super_admin`
- **Response**: `200 OK`
```json
[
  {
    "market_id": "a3bb189e-8bf9-3888-9912-ace4e6543002",
    "slug": "remo-stars-vs-sporting-lagos",
    "question": "Will Remo Stars defeat Sporting Lagos?",
    "state": "PROPOSED",
    "stage_label": "Dispute window open",
    "meta": "Proposed Yes · 1 dispute",
    "conflict": false,
    "overdue": false
  }
]
```

### 3.2 Resolution Market Detail & Audit
- **Endpoint**: `GET /v1/admin/resolution/markets/:market_id`
- **Auth**: `resolver` or `super_admin`
- **Response**: `200 OK`
```json
{
  "market_id": "a3bb189e-8bf9-3888-9912-ace4e6543002",
  "slug": "remo-stars-vs-sporting-lagos",
  "question": "Will Remo Stars defeat Sporting Lagos?",
  "state": "PROPOSED",
  "version": 1,
  "conflict": false,
  "overdue": false,
  "dispute_until": "2026-10-28T18:30:00Z",
  "proposed_outcome": "YES",
  "proposed_reason": "FT report verified score 2-1",
  "hold_reason": "",
  "final_outcome": "",
  "final_reason": "",
  "decided_at": "",
  "evidence": [
    {
      "id": "e0a12e34-5678-4901-abcd-ef0123456789",
      "source_id": "system_collector",
      "url": "https://sports.example.com/match/remo-stars-vs-sporting-lagos",
      "retrieved_at": "2026-10-28T18:00:00Z",
      "http_status": 200,
      "content_type": "text/html",
      "snapshot_ref": "snap:remo-stars-vs-sporting-lagos",
      "sha256": "4b227777d4dd1fc61c6f884f48641d02b4d121d3fd328cb08b5531fcacdabf8a",
      "finding": "FT: Remo Stars 2 - 1 Sporting Lagos",
      "verdict": "SAYS_YES",
      "collected_by": "system_collector"
    }
  ],
  "disputes": [
    {
      "id": "d1a12e34-5678-4901-abcd-ef0123456789",
      "account_id": "u1a12e34-5678-4901-abcd-ef0123456789",
      "holdings_proof": "Held 100 Yes shares at close",
      "reason": "The referee disallowed the second goal on VAR review after the final whistle.",
      "link_url": "https://league.example.com/official-corrections/1029",
      "decision": null,
      "decision_note": "",
      "decided_by": null,
      "decided_at": null,
      "created_at": "2026-10-28T18:10:00Z"
    }
  ],
  "preview": {
    "outcome": "YES",
    "total_winners": 42,
    "total_payout": 4200,
    "total_collateral_released": 4200,
    "treasury_shortfall": 0
  }
}
```

### 3.3 Add Manual Evidence
- **Endpoint**: `POST /v1/admin/resolution/markets/:market_id/evidence`
- **Auth**: `resolver` or `super_admin`
- **Request Body**:
```json
{
  "url": "https://sports.example.com/match/remo-stars-vs-sporting-lagos",
  "note": "FT: Remo Stars 2 - 1 Sporting Lagos. Remo Stars wins!"
}
```
- **Response**: `200 OK`
```json
{
  "evidence_id": "e0a12e34-5678-4901-abcd-ef0123456789"
}
```

### 3.4 Refresh Evidence (Automated Adapters)
- **Endpoint**: `POST /v1/admin/resolution/markets/:market_id/refresh-evidence`
- **Auth**: `resolver` or `super_admin`
- **Response**: `200 OK`
```json
{
  "ok": true
}
```

### 3.5 Propose Outcome
- **Endpoint**: `POST /v1/admin/resolution/markets/:market_id/propose`
- **Auth**: `resolver` or `super_admin`
- **Rules**:
  - Requires at least 1 piece of supporting evidence.
  - Resets dispute window to 30 minutes if outcome differs from previous proposal.
  - Requires optimistic concurrency `version`.
- **Request Body**:
```json
{
  "outcome": "YES",
  "reason": "Official match score confirms Remo Stars victory.",
  "evidence_ids": ["e0a12e34-5678-4901-abcd-ef0123456789"],
  "version": 1
}
```
- **Response**: `200 OK`
```json
{
  "ok": true
}
```

### 3.6 Hold Resolution
- **Endpoint**: `POST /v1/admin/resolution/markets/:market_id/hold`
- **Auth**: `resolver` or `super_admin`
- **Request Body**:
```json
{
  "reason": "Investigating disputed post-match VAR penalty ruling.",
  "version": 2
}
```
- **Response**: `200 OK`
```json
{
  "ok": true
}
```

### 3.7 Decide Dispute
- **Endpoint**: `POST /v1/admin/resolution/markets/:market_id/disputes/:id/decide`
- **Auth**: `super_admin` strictly
- **Request Body**:
```json
{
  "decision": "DISMISSED",
  "note": "VAR review occurred prior to final whistle; score 2-1 stands."
}
```
- **Response**: `200 OK`
```json
{
  "ok": true
}
```

### 3.8 Finalize Resolution
- **Endpoint**: `POST /v1/admin/resolution/markets/:market_id/finalize`
- **Auth**: `super_admin` strictly
- **Rules**:
  - `finalizer_id != proposer_id` (a user cannot finalize their own proposal).
  - Dispute window must have closed (`now() >= dispute_until`).
  - All submitted disputes must be decided (`decision is not null`).
  - If outcome is `VOID` and shortfall exceeds 50,000 Sedis, requires 2 approved super admin signatures on `void_shortfall`.
  - Atomically creates `settlement_jobs` and initiates batch processing.
- **Request Body**:
```json
{
  "outcome": "YES",
  "void_reason": null,
  "reason": "Final score audited and all player disputes reviewed.",
  "version": 2
}
```
- **Response**: `200 OK`
```json
{
  "status": "FINALIZED",
  "outcome": "YES",
  "dispute_until": "",
  "message": "Market resolved YES and settlement initiated"
}
```

### 3.9 Settlement Progress
- **Endpoint**: `GET /v1/admin/resolution/markets/:market_id/settlement-progress`
- **Auth**: `resolver` or `super_admin`
- **Response**: `200 OK`
```json
{
  "market_id": "a3bb189e-8bf9-3888-9912-ace4e6543002",
  "decision_id": "dec_0123456789",
  "state": "DONE",
  "cursor": 42,
  "done": true,
  "winners_count": 42,
  "payout_total": 4200,
  "refunds_total": 0,
  "fee_refunds_total": 0,
  "collateral_released": 4200,
  "treasury_delta": 0,
  "shortfall": 0,
  "error_message": null
}
```
