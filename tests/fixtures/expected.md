# Purview DLP Baseline — acme

- Date: 20260521
- Policies: 3
- Rules: 4

## Policy: Block Credential Leakage

- Mode: Enable
- Enabled: True
- Workload: Exchange,SharePoint,OneDriveForBusiness
- Priority: 0
- Comment: Tier-1 credential SITs, enforced.

### Rule: Block AWS Access Keys

- Mode: Enable
- Priority: 0
- Disabled: False
- Conditions: SIT *AWS Access Key*
- Actions: block; notify: LastModifier, Owner
- Comment: Tier-1.

### Rule: Block Orphan SIT Reference

- Mode: Enable
- Priority: 1
- Disabled: False
- Conditions: SIT *<orphan id=sit-deleted-orphan-99999>*
- Actions: block
- Comment: Rule points at a SIT that no longer exists.

## Policy: Legacy Keyword Blocks

- Mode: Enable
- Enabled: False
- Workload: Exchange
- Priority: 2
- Comment: Disabled pending realignment review.

### Rule: Block Credit Card Number Phrases

- Mode: Enable
- Priority: 0
- Disabled: True
- Conditions: keywords: card number, credit card, cvv
- Actions: incident report: Owner
- Comment: Disabled; keyword approach superseded.

## Policy: Sensitivity Label Enforcement

- Mode: TestWithNotifications
- Enabled: True
- Workload: Exchange
- Priority: 1
- Comment: Label-conditioned, currently in simulation.

### Rule: Block Highly Confidential External

- Mode: TestWithNotifications
- Priority: 0
- Disabled: False
- Conditions: label *Highly Confidential*
- Actions: block
- Except if recipient domain in: example.com
- Comment: Label-conditioned.

