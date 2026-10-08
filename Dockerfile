FROM oven/bun:1-slim
WORKDIR /app
COPY docs/ ./docs/
RUN bun add serve
EXPOSE 7860
CMD ["bunx", "serve", "docs", "-l", "7860"]
