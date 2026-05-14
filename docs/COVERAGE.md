# AWS S3 Smithy coverage

Generated from `s3.json` and `src/router.zig`.

**Coverage: 68 / 107 operations (63.6%)**

## Covered (68)

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
- DeleteBucketReplication
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
- GetBucketPolicyStatus
- GetBucketReplication
- GetBucketTagging
- GetBucketVersioning
- GetBucketWebsite
- GetObject
- GetObjectAcl
- GetObjectAttributes
- GetObjectLegalHold
- GetObjectLockConfiguration
- GetObjectRetention
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
- PutBucketReplication
- PutBucketTagging
- PutBucketVersioning
- PutBucketWebsite
- PutObject
- PutObjectAcl
- PutObjectLegalHold
- PutObjectLockConfiguration
- PutObjectRetention
- PutObjectTagging
- PutPublicAccessBlock
- RestoreObject
- UpdateObjectEncryption
- UploadPart
- UploadPartCopy — *Dispatched from upload_part when x-amz-copy-source header is present*

## Unrouted (39)

Grouped thematically. Most of these are explicit non-goals for v1.x (PRD §15) — kept here as the AWS-side checklist.

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

### Object torrent (1)

- GetObjectTorrent

### Object-level (other) (2)

- RenameObject
- WriteGetObjectResponse

### Other (1)

- CreateSession

### Request payment (2)

- GetBucketRequestPayment
- PutBucketRequestPayment

### Restore / Glacier (1)

- SelectObjectContent

