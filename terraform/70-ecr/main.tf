# ============================================================
# ECR REPOSITORIES — PRIVATE DOCKER IMAGE STORAGE
#
# Two repositories:
#   expense-backend  — the Node.js API image (built by CI/CD)
#   expense-frontend — the frontend image (if/when added)
#
# Security settings:
#   image_tag_mutability = IMMUTABLE
#     Once an image is pushed with tag "abc1234", that tag can never
#     be overwritten. This prevents "tag poisoning" — an attacker
#     can't replace your known-good image with a malicious one by
#     pushing to the same tag. Every commit gets a unique, permanent tag.
#
#   scan_on_push = true
#     Every time a new image is pushed, ECR automatically scans it
#     against the CVE database (a global list of known vulnerabilities).
#     Results appear in the ECR console within ~1-2 minutes.
#     The CI/CD pipeline reads these results and FAILS the deploy
#     if any CRITICAL vulnerabilities are found (see deploy.yml).
#
# Lifecycle policy (on each repo):
#   Keeps storage costs low by automatically deleting old images.
#   Rule 1: untagged images (orphaned build artifacts) → delete after 1 day
#   Rule 2: tagged images → keep only the 10 most recent
#   This prevents the repo from filling up with hundreds of old images
#   that nobody will ever pull again.
# ============================================================


resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true   # ECR scans every pushed image against the CVE database
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-backend"
  })
}

# Lifecycle policy for the backend repo.
# Think of it like a DVR set to record only the last 10 episodes —
# older ones are automatically deleted to save disk space.
resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        # Rule 1: delete untagged images after 1 day.
        # Untagged images are created when 'latest' is re-pushed —
        # the old 'latest' loses its tag and becomes an orphan.
        # These orphans serve no purpose and cost money to store.
        rulePriority = 1
        description  = "Delete untagged (orphaned) images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        # Rule 2: keep only the 10 most recent tagged images.
        # You can always roll back to any of the last 10 commits.
        # Anything older than 10 releases is unlikely to ever be needed.
        rulePriority = 2
        description  = "Keep only 10 most recent tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["${var.project_name}"]   # matches tags like "expense-abc1234"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}


resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-frontend"
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged (orphaned) images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only 10 most recent tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["${var.project_name}"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}