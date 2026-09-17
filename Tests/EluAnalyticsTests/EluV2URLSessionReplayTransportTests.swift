import Foundation
import XCTest
@testable import EluAnalytics

final class EluV2URLSessionReplayTransportTests: XCTestCase {
    func testExactReplayRoleBytesHeadersAndNoAmbientCookies() async throws {
        let (h,dispatch,claim) = try await enrolled(); defer { h.remove() }
        ReplayTransportURLProtocol.hooks.set { request, client, instance in
            XCTAssertEqual(request.url?.absoluteString, "https://ingest.elu.dev/v2/replay")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"), "Bearer elu_pk_test_aaaaaaaaaaaaaaaaaaaaaa")
            XCTAssertFalse(request.httpShouldHandleCookies)
            client.urlProtocol(instance,didReceive:Self.response(request,status:200),cacheStoragePolicy:.notAllowed)
            client.urlProtocol(instance,didLoad:Data("reply".utf8));client.urlProtocolDidFinishLoading(instance)
        }
        let result = try await transport().send(dispatch)
        XCTAssertEqual(result.status,200);XCTAssertEqual(result.body,Data("reply".utf8))
        _ = try await h.queue.finishReplayClaim(claim,completion:.released)
        await h.queue.close()
    }
    func testWithdrawnOriginalSourcePreventsPhysicalStart() async throws {
        let (h,dispatch,claim) = try await enrolled();defer{h.remove()}
        ReplayTransportURLProtocol.hooks.set { _,_,_ in XCTFail("Invalid dispatch") }
        h.gate.publish(token:EluV2ConfigLifecycleToken(),lease:nil)
        do{_ = try await transport().send(dispatch);XCTFail("Stale dispatch")}
        catch{XCTAssertEqual(error as? EluV1BoundTransportError,.staleAuthority)}
        _ = try await h.queue.finishReplayClaim(claim,completion:.released)
        await h.queue.close()
    }
    func test401And403SurviveUnreadableOversizedBody() async throws {
        for status in [401,403] {
            let (h,dispatch,claim) = try await enrolled();defer{h.remove()}
            ReplayTransportURLProtocol.hooks.set { request,client,instance in
                client.urlProtocol(instance,didReceive:Self.response(request,status:status,headers:["Content-Length":"99999999"]),cacheStoragePolicy:.notAllowed)
                client.urlProtocol(instance,didLoad:Data([255]));client.urlProtocolDidFinishLoading(instance)
            }
            let value = try await transport().send(dispatch)
            XCTAssertEqual(value.status,status);XCTAssertTrue(value.body.isEmpty)
            _ = try await h.queue.finishReplayClaim(claim,completion:.response(.credentialBlocked(status:status)))
            await h.queue.close()
        }
    }
    func testDuplicateDispatchCannotReleaseFirstPhysicalLeaseAfterOwnerClose() async throws {
        let (h,dispatch,claim) = try await enrolled();defer{h.remove()}
        let began=expectation(description:"started"), concrete=transport()
        ReplayTransportURLProtocol.hooks.set{_,_,_ in began.fulfill()}
        let task=Task{try await concrete.send(dispatch)}
        await fulfillment(of:[began],timeout:2)
        await h.queue.close()
        do{_ = try await concrete.send(dispatch);XCTFail("Duplicate physical use")}
        catch{XCTAssertEqual(error as? EluV1BoundTransportError,.occupied)}
        dispatch.cancelUnused()
        do{let next=try await h.reopen();await next.close();XCTFail("Old lease released while request live")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ownershipConflict)}
        task.cancel();do{_ = try await task.value;XCTFail("Canceled succeeded")}catch{}
        do{let next=try await h.reopen();await next.close();XCTFail("Receipt barrier released early")}
        catch{XCTAssertEqual(error as? EluRuntimeQueueError,.ownershipConflict)}
        _ = try await h.queue.finishReplayClaim(claim,completion:.released)
        let next=try await h.reopen();await next.close()
    }
    func testSessionDisablesAmbientCredentialsAndPreservesDefaultServerTrust() {
        let configuration = EluV2ReplaySessionPolicy.configuration(timeout: 20, protocolClasses: nil)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodNTLM,
                       NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate] {
            let space = URLProtectionSpace(host: "ingest.elu.dev", port: 443, protocol: "https", realm: "fixture", authenticationMethod: method)
            XCTAssertEqual(EluV2ReplaySessionPolicy.disposition(space), .cancelAuthenticationChallenge)
        }
        let trust = URLProtectionSpace(host: "ingest.elu.dev", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
        XCTAssertEqual(EluV2ReplaySessionPolicy.disposition(trust), .performDefaultHandling)
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodServerTrust] {
            let proxy = URLProtectionSpace(proxyHost: "proxy.invalid", port: 443, type: NSURLProtectionSpaceHTTPSProxy, realm: "fixture", authenticationMethod: method)
            XCTAssertEqual(EluV2ReplaySessionPolicy.disposition(proxy), .cancelAuthenticationChallenge)
        }
    }

    private func enrolled() async throws -> (DeliveryHarness,EluV2ReplayDispatch,EluV2ReplayClaim) {
        let h=try await DeliveryHarness.make();try await h.install();_ = try await h.append();try await h.queue.ensureReplayDeliverySchema()
        let authority=try await h.deliveryAuthority()
        guard case let .claimed(claim)=try await h.queue.claimNextReplay(authority),let dispatch=try await h.queue.enrollReplayDispatch(claim,dispatchAllowed:{true}) else{throw EluRuntimeQueueError.invalidState}
        let duplicate=try await h.queue.enrollReplayDispatch(claim,dispatchAllowed:{true});XCTAssertNil(duplicate)
        return(h,dispatch,claim)
    }
    private func transport()->EluV2URLSessionReplayTransport{EluV2URLSessionReplayTransport(protocolClasses:[ReplayTransportURLProtocol.self])}
    private static func response(_ request:URLRequest,status:Int,headers:[String:String]=[:])->HTTPURLResponse{
        HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers)!
    }
}
private final class ReplayTransportURLProtocol:URLProtocol,@unchecked Sendable{
    static let hooks=Hooks()
    final class Hooks:@unchecked Sendable{
        private let lock=NSLock()
        private var callback:(URLRequest,URLProtocolClient,URLProtocol)->Void={_,_,_ in}
        func set(_ value:@escaping(URLRequest,URLProtocolClient,URLProtocol)->Void){lock.lock();callback=value;lock.unlock()}
        func begin(_ request:URLRequest,_ client:URLProtocolClient,_ instance:URLProtocol){lock.lock();let value=callback;lock.unlock();value(request,client,instance)}
    }
    override class func canInit(with _:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){if let client{Self.hooks.begin(request,client,self)}}
    override func stopLoading(){}
}
