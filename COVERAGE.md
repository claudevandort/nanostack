# AWS S3 Smithy coverage

Generated from `s3.json` and `src/router.zig`.

**Coverage: 56 / 107 operations (52.3%)**

## Covered (56)

- AbortMultipartUpload
- CompleteMultipartUpload
- CopyObject — *Dispatched from put_object when x-amz-copy-source header is present*
- CreateBucket
- CreateMultipartUpload
- DeleteBucket
- DeleteBucketCors
- DeleteBucketEncryption
- DeleteBucketLifecycle
- DeleteBucketOwnershipControls
- DeleteBucketPolicy
- DeleteBucketTagging
- DeleteBucketWebsite
- DeleteObject
- DeleteObjectTagging
- DeleteObjects
- DeletePublicAccessBlock
- GetBucketAcl
- GetBucketCors
- GetBucketEncryption
- GetBucketLifecycleConfiguration
- GetBucketNotificationConfiguration
- GetBucketOwnershipControls
- GetBucketPolicy
- GetBucketTagging
- GetBucketVersioning
- GetBucketWebsite
- GetObject
- GetObjectAcl
- GetObjectAttributes
- GetObjectTagging
- GetPublicAccessBlock
- HeadBucket
- HeadObject
- ListBuckets
- ListMultipartUploads
- ListObjectVersions
- ListObjects
- ListObjectsV2
- ListParts
- PutBucketAcl
- PutBucketCors
- PutBucketEncryption
- PutBucketLifecycleConfiguration
- PutBucketNotificationConfiguration
- PutBucketOwnershipControls
- PutBucketPolicy
- PutBucketTagging
- PutBucketVersioning
- PutBucketWebsite
- PutObject
- PutObjectAcl
- PutObjectTagging
- PutPublicAccessBlock
- UploadPart
- UploadPartCopy — *Dispatched from upload_part when x-amz-copy-source header is present*

## Unrouted (51)

Grouped thematically. Most of these are explicit non-goals for v1.x (PRD §15) — kept here as the AWS-side checklist.

### ACL / policy / ownership (1)

- GetBucketPolicyStatus

### Accelerate (2)

- GetBucketAccelerateConfiguration
- PutBucketAccelerateConfiguration

### Analytics (4)

- DeleteBucketAnalyticsConfiguration
- GetBucketAnalyticsConfiguration
- ListBucketAnalyticsConfigurations
- PutBucketAnalyticsConfiguration

### Attributes / metadata (8)

- CreateBucketMetadataConfiguration
- CreateBucketMetadataTableConfiguration
- DeleteBucketMetadataConfiguration
- DeleteBucketMetadataTableConfiguration
- GetBucketMetadataConfiguration
- GetBucketMetadataTableConfiguration
- UpdateBucketMetadataInventoryTableConfiguration
- UpdateBucketMetadataJournalTableConfiguration

### Bucket-level (other) (4)

- GetBucketAbac
- GetBucketLocation
- ListDirectoryBuckets
- PutBucketAbac

### Encryption / SSE (1)

- UpdateObjectEncryption

### Intelligent tiering (4)

- DeleteBucketIntelligentTieringConfiguration
- GetBucketIntelligentTieringConfiguration
- ListBucketIntelligentTieringConfigurations
- PutBucketIntelligentTieringConfiguration

### Inventory (4)

- DeleteBucketInventoryConfiguration
- GetBucketInventoryConfiguration
- ListBucketInventoryConfigurations
- PutBucketInventoryConfiguration

### Logging (2)

- GetBucketLogging
- PutBucketLogging

### Metrics (4)

- DeleteBucketMetricsConfiguration
- GetBucketMetricsConfiguration
- ListBucketMetricsConfigurations
- PutBucketMetricsConfiguration

### Object Lock / retention / legal hold (6)

- GetObjectLegalHold
- GetObjectLockConfiguration
- GetObjectRetention
- PutObjectLegalHold
- PutObjectLockConfiguration
- PutObjectRetention

### Object torrent (1)

- GetObjectTorrent

### Object-level (other) (2)

- RenameObject
- WriteGetObjectResponse

### Other (1)

- CreateSession

### Replication (3)

- DeleteBucketReplication
- GetBucketReplication
- PutBucketReplication

### Request payment (2)

- GetBucketRequestPayment
- PutBucketRequestPayment

### Restore / Glacier (2)

- RestoreObject
- SelectObjectContent

