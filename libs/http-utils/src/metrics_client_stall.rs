// neondatabase/neon#12954: a /metrics client that stops reading must not hold a blocking-pool thread for ever (the
// reproduction in the issue showed one stalled scrape starving a runtime with one blocking thread).

use std::time::Duration;

use hyper::{Body, Request};

use crate::endpoint::prometheus_metrics_handler_with;

const STALL_LIMIT: Duration = Duration::from_millis(300);

fn scrape_request() -> Request<Body> {
    Request::builder().uri("/metrics").body(Body::empty()).expect("valid request")
}

fn single_blocking_thread_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .max_blocking_threads(1)
        .enable_all()
        .build()
        .expect("runtime builds")
}

#[test]
fn a_stalled_metrics_client_gives_the_blocking_thread_back() {
    let rt = single_blocking_thread_runtime();
    rt.block_on(async {
        // Never poll the response body: the stalled client
        let _response = prometheus_metrics_handler_with(scrape_request(), true, STALL_LIMIT)
            .await
            .expect("handler responds");
        // Once the writer gives up on it, other blocking work runs, the client still not reading
        tokio::time::timeout(STALL_LIMIT * 10, tokio::task::spawn_blocking(|| ()))
            .await
            .expect("the blocking pool is free again after the stall limit")
            .expect("blocking task runs");
    });
}

#[test]
fn a_reading_metrics_client_gets_the_whole_response() {
    let rt = single_blocking_thread_runtime();
    rt.block_on(async {
        let response = prometheus_metrics_handler_with(scrape_request(), true, STALL_LIMIT)
            .await
            .expect("handler responds");
        let body = hyper::body::to_bytes(response.into_body()).await.expect("body is readable");
        assert!(!body.is_empty(), "metrics payload is not empty");
    });
}
