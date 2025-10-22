docker buildx build --platform linux/amd64,linux/arm64 -t mikelarg/aegra:0.0.4 . 
docker image push mikelarg/aegra:0.0.4   