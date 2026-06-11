# JSON-RPC 2.0 Schema

## Overview

The JSON-RPC 2.0 protocol specifies a standard for communication between clients and servers. Each message is a JSON object containing the fields required for communication.

### Required Fields
- `jsonrpc`: A string specifying the version of the JSON-RPC protocol (must be `"2.0"`).
- `method`: A string containing the name of the method to be invoked.
- `params`: A structured value that holds the parameters for the method (optional).
- `id`: A unique identifier for the request (optional).

### Error Handling
Responses must clearly indicate errors when they occur, according to the JSON-RPC specification.