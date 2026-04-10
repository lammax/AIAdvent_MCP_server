//
//  File.swift
//  MCPServer
//
//  Created by Максим Ламанский on 10.04.26.
//

import Foundation
import Vapor
import MCP
internal import NIOFoundationCompat

public func mcpHeaders(from headers: HTTPHeaders) -> [String: String] {
    var result: [String: String] = [:]
    for header in headers {
        result[header.name] = header.value
    }
    return result
}

public func vaporResponse(from response: HTTPResponse) -> Vapor.Response {
    var headers = HTTPHeaders()
    for (name, value) in response.headers {
        headers.add(name: name, value: value)
    }

    let data = response.bodyData ?? Data()

    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)

    return Response(
        status: HTTPResponseStatus(statusCode: response.statusCode),
        headers: headers,
        body: .init(buffer: buffer)
    )
}
