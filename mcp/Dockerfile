# For MCP directories that start the server in a container to read its tools.
# In a container the keepmacawake command is out of reach, so every tool answers
# that Keep Mac Awake runs only on the user's Mac; use it on the Mac with npx.
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY bin ./bin
COPY src ./src
USER node
ENTRYPOINT ["node", "bin/keepmacawake-mcp.mjs"]
