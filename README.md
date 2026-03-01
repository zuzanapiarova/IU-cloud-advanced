# Cloud Architecture for Financial Transactions Platform

This project is created for the selective module Cloud Advanced at IU International University of Applied Sciences.

(steps to replicate architecture with tf below)

### Task:

The task was to design a cloud architecture for a fictional startup processing transctions between users and institutions. The requirements were high availability, disaster recovery, and security compliance with PCI DSS for processing payer data, all while keeping the budget under $1 and leveraging the free tier services. AWS Well-Architected framework Finansial Services Lens Payment Scenario was used as basis of the design.

### Architecture Design

To summarize the final design of hte production architecture, the user interacts with the web service and the requests are routed through Route53 to Cloudfront. Cloudfront has one path pointing to an S3 bucket, which is encrypted, and second path pointing to the API Gateway over TLS. The API gateway performs validation and authorisation and routes the request to Application Load Balancer in the public subnet. ALB distributes requests to ECS tasks EC2 instances that are in an autoscaling group in a private subnet. ECS container images are stored in ECR. RDS is deployed in the private subnet. Snapshots of the database are stored automatically in an S3 bucket for disaster recovery. Data is encrypted in rest and in transit. In production, multiple availability zones are leveraged for high-availability and resilience. External connectivity is provided by a NAT Gateway for third-part API services and VPN Gateway with site-to-site VPN for on-premise or cloud organization networks. Security is provided via security groups, IAM, AWS KMS, AWS Systems Manager parameter store. Monitoring is provided by Cloudwatch, Cloudtrail, and AWS config, all of which store logs to the S3.

![Cloud architecture for production diagram](images/production_architecture.png "Cloud architecture for production diagram")

In the Proof-of-Concept implementation, minor changes were made, and the services that were required in the production implementation but do not provide a sufficient or similar option are omitted. These are the external connectivity components NAT Gateway and VPN Gateway. Route53 is omitted and instead, the user connects directly to the Cloudfront endpoint. A single EC2 t2.micro instance in one availability zone is deployed, with ASG configured to maintain exactly 1 instance running. RDS is also deployed  in one instance, with multi-az deployment disabled. 

![Cloud architecture for PoC diagram](images/poc_architecture.png "Cloud architecture for Proof-of-Concept diagram")

### Implementation

Mock frontend and backend were created. Frontend is built into the ./dist folder and the static files are copied to S3. Backend is packaged into a docker container and pushed to ECR, from where the ECS tasks retrieve it. The PoC architecture was implemented through AWS, tested to ensure requests are routed to the proper components and return a response, then automated using Terraform. Endpoint to test the connection is provided as the output. 

### Replicate the infrastructure with Terraform

1. AWS, Docker, terraform, and npm utilities are required. User must also log into the aws via cli using heir credentials beforehand.

2. Run the ./deploy.sh script. It deploys the cloud services, builds the frontend and backend and pushes the artifacts to the services. 

3. Finally, the endpoint on which to test the connection is output.