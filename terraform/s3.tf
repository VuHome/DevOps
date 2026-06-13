locals {
  buckets = ["vuhom-listing", "vuhom-profile", "vuhom-operator"]
}

resource "aws_s3_bucket" "app" {
  for_each = toset(local.buckets)
  bucket   = each.key
}

resource "aws_s3_bucket_public_access_block" "app" {
  for_each = toset(local.buckets)
  bucket   = aws_s3_bucket.app[each.key].id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_acl" "app" {
  for_each = toset(local.buckets)
  bucket   = aws_s3_bucket.app[each.key].id
  acl      = "public-read"

  depends_on = [aws_s3_bucket_public_access_block.app]
}
