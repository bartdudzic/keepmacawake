# For MCP directories that start the server in a container to read its tools.
# In a container the keepmacawake command is out of reach, so the tools list as
# usual and each call answers that Keep Mac Awake runs only on the user's Mac;
# use it on the Mac with npx.
#
#   docker build -t keepmacawake-mcp mcp
#   docker run -i --rm keepmacawake-mcp
FROM node:24-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY bin ./bin
COPY src ./src
USER node
ENTRYPOINT ["node", "bin/keepmacawake-mcp.mjs"]
