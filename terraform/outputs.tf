output "alb_dns_name" {
  description = "Paste this in your browser"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "RDS endpoint stored in Secrets Manager - no manual action needed"
  value       = aws_db_instance.mysql.address
  sensitive   = true
}
