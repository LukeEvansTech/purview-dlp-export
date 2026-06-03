# Purview DLP Overview - acme

- Date: 20260601
- Policies: 3 (2 enforce, 1 test)
- Rules: 5 (1 disabled)

| Policy | Mode | Workloads | Rules | Detects | Acts | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Block Credential Leakage | Enforce | Exchange, SharePoint, OneDrive | 3 | AWS Access Key; <orphan id=sit-deleted-orphan-99999>; U.K. Driver's License Number, Credit Card Number | Block access; Notify | 0 |
| Sensitivity Label Enforcement | Test (notify) | Exchange | 1 | Highly Confidential | Block access | 1 |
| Legacy Keyword Blocks | Enforce (off) | Exchange | 1 | - | Incident report to | 2 |
