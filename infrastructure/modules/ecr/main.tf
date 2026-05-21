################################################################################
# ECR Repositories — Workshop Container Images
#
# Pre-creates ECR repositories so build scripts only push images (no ad-hoc
# `aws ecr create-repository`). force_delete = true lets `terraform destroy`
# remove repos even when they contain images.
################################################################################

resource "aws_ecr_repository" "workshop" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}
