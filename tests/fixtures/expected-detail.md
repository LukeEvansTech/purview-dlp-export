# Purview DLP Detail - acme

- Date: 20260601

## Policy: Block Credential Leakage

- Mode: Enforce
- Enabled: True
- Priority: 0
- Applies to: Exchange, SharePoint, OneDrive
- Comment: Tier-1 credential SITs, enforced.

### Rule: Block AWS Access Keys

- Mode: Enforce
- Enabled: True
- Priority: 0
- Detects: AWS Access Key
- Conditions:
  - SIT: AWS Access Key
- Actions:
  - Block access
  - Notify: LastModifier, Owner
- Comment: Tier-1.

### Rule: Block Orphan SIT Reference

- Mode: Enforce
- Enabled: True
- Priority: 1
- Detects: <orphan id=sit-deleted-orphan-99999>
- Conditions:
  - SIT: <orphan id=sit-deleted-orphan-99999>
- Actions:
  - Block access
- Comment: Rule points at a SIT that no longer exists.

### Rule: Block UK PII (Advanced Rule)

- Mode: Enforce
- Enabled: True
- Priority: 5
- Detects: U.K. Driver's License Number, Credit Card Number
- Conditions:
  - SIT: U.K. Driver's License Number (medium confidence, 10+ instances)
  - SIT: Credit Card Number (high confidence, 1+ instances)
- Actions:
  - Block access

## Policy: Sensitivity Label Enforcement

- Mode: Test (notify)
- Enabled: True
- Priority: 1
- Applies to: Exchange
- Comment: Label-conditioned, currently in simulation.

### Rule: Block Highly Confidential External

- Mode: Test (notify)
- Enabled: True
- Priority: 0
- Detects: Highly Confidential
- Conditions:
  - Label: Highly Confidential
- Actions:
  - Block access
- Exceptions:
  - Recipient domain in: example.com
- Comment: Label-conditioned.

## Policy: Legacy Keyword Blocks

- Mode: Enforce
- Enabled: False
- Priority: 2
- Applies to: Exchange
- Comment: Disabled pending realignment review.

### Rule: Block Credit Card Number Phrases

- Mode: Enforce
- Enabled: False
- Priority: 0
- Detects: (no sensitive-info type; see conditions)
- Conditions:
  - Keywords: card number, credit card, cvv
  - File extensions: pan, card-number
- Actions:
  - Incident report to: Owner
- Comment: Disabled; keyword approach superseded.

