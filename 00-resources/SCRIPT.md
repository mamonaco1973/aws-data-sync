# Video Script — AWS DataSync: EFS to S3 Data Migration

---

## Introduction

[Show DataSync task executions running with throughput and file counts updating]

Moving large datasets between storage systems can be complicated. You need reliable transfers, integrity checks, and the ability to run migrations at scale.

[Show Task Details]

AWS DataSync is a managed service designed for this problem. 

[Show AWS source and target locations]

It moves data between storage systems efficiently while handling scheduling, retries, verification, and incremental transfers so large migrations can stay synchronized until the final cutover.

[Show the full migration flow diagram briefly with no highlights]

In this project we'll build a complete DataSync migration pipeline using Terraform and watch it move data between storage systems.

---
