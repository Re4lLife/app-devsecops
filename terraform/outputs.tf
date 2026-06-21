output "alb_dns_name" {
  description = "Paste this in your browser"
  value       = aws_lb.main.dns_name
}

