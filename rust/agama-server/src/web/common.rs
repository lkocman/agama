//! This module defines functions to be used accross all services.

use std::{pin::Pin, task::Poll};

use agama_lib::{
    error::ServiceError,
    progress::Progress,
    proxies::{ProgressProxy, ServiceStatusProxy},
};
use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use pin_project::pin_project;
use serde::Serialize;
use serde_json::json;
use thiserror::Error;
use tokio_stream::{Stream, StreamExt};
use zbus::PropertyStream;

use crate::error::Error;

use super::Event;

/// Builds a router to the `org.opensuse.Agama1.ServiceStatus`
/// interface of the given D-Bus object.
///
/// ```no_run
/// # use axum::{extract::State, routing::get, Json, Router};
/// # use agama_lib::connection;
/// # use agama_server::web::common::service_status_router;
/// # use tokio_test;
///
/// # tokio_test::block_on(async {
/// async fn hello(state: State<HelloWorldState>) {};
///
/// #[derive(Clone)]
/// struct HelloWorldState {};
///
/// let dbus = connection().await.unwrap();
/// let status_router = service_status_router(
///   &dbus, "org.opensuse.HelloWorld", "/org/opensuse/hello"
/// ).await.unwrap();
/// let router: Router<HelloWorldState> = Router::new()
///   .route("/hello", get(hello))
///   .merge(status_router)
///   .with_state(HelloWorldState {});
/// });
/// ```
///
/// * `dbus`: D-Bus connection.
/// * `destination`: D-Bus service name.
/// * `path`: D-Bus object path.
pub async fn service_status_router<T>(
    dbus: &zbus::Connection,
    destination: &str,
    path: &str,
) -> Result<Router<T>, ServiceError> {
    let proxy = build_service_status_proxy(dbus, destination, path).await?;
    let state = ServiceStatusState { proxy };
    Ok(Router::new()
        .route("/status", get(service_status))
        .with_state(state))
}

async fn service_status(State(state): State<ServiceStatusState<'_>>) -> Json<ServiceStatus> {
    Json(ServiceStatus {
        current: state.proxy.current().await.unwrap(),
    })
}

#[derive(Clone)]
struct ServiceStatusState<'a> {
    proxy: ServiceStatusProxy<'a>,
}

#[derive(Clone, Serialize)]
struct ServiceStatus {
    /// Current service status.
    current: u32,
}

#[derive(Error, Debug)]
pub enum ServiceStatusError {
    #[error("Service status error: {0}")]
    Error(#[from] ServiceError),
}

impl IntoResponse for ServiceStatusError {
    fn into_response(self) -> Response {
        let body = json!({
            "error": self.to_string()
        });
        (StatusCode::BAD_REQUEST, Json(body)).into_response()
    }
}

/// Builds a stream of the changes in the the `org.opensuse.Agama1.ServiceStatus`
/// interface of the given D-Bus object.
///
/// * `dbus`: D-Bus connection.
/// * `destination`: D-Bus service name.
/// * `path`: D-Bus object path.
pub async fn service_status_stream(
    dbus: zbus::Connection,
    destination: &'static str,
    path: &'static str,
) -> Result<Pin<Box<dyn Stream<Item = Event> + Send>>, Error> {
    let proxy = build_service_status_proxy(&dbus, destination, path).await?;
    let stream = proxy
        .receive_current_changed()
        .await
        .then(move |change| async move {
            if let Ok(status) = change.get().await {
                Some(Event::ServiceStatusChanged {
                    service: destination.to_string(),
                    status,
                })
            } else {
                None
            }
        })
        .filter_map(|e| e);
    Ok(Box::pin(stream))
}

async fn build_service_status_proxy<'a>(
    dbus: &zbus::Connection,
    destination: &str,
    path: &str,
) -> Result<ServiceStatusProxy<'a>, zbus::Error> {
    let proxy = ServiceStatusProxy::builder(&dbus)
        .destination(destination.to_string())?
        .path(path.to_string())?
        .build()
        .await?;
    Ok(proxy)
}

/// Builds a router to the `org.opensuse.Agama1.Progress`
/// interface of the given D-Bus object.
///
/// ```no_run
/// # use axum::{extract::State, routing::get, Json, Router};
/// # use agama_lib::connection;
/// # use agama_server::web::common::progress_router;
/// # use tokio_test;
///
/// # tokio_test::block_on(async {
/// async fn hello(state: State<HelloWorldState>) {};
///
/// #[derive(Clone)]
/// struct HelloWorldState {};
///
/// let dbus = connection().await.unwrap();
/// let progress_router = progress_router(
///   &dbus, "org.opensuse.HelloWorld", "/org/opensuse/hello"
/// ).await.unwrap();
/// let router: Router<HelloWorldState> = Router::new()
///   .route("/hello", get(hello))
///   .merge(progress)
///   .with_state(HelloWorldState {});
/// });
/// ```
///
/// * `dbus`: D-Bus connection.
/// * `destination`: D-Bus service name.
/// * `path`: D-Bus object path.
pub async fn progress_router<T>(
    dbus: &zbus::Connection,
    destination: &str,
    path: &str,
) -> Result<Router<T>, ServiceError> {
    let proxy = build_progress_proxy(dbus, destination, path).await?;
    let state = ProgressState { proxy };
    Ok(Router::new()
        .route("/progress", get(progress))
        .with_state(state))
}

#[derive(Clone)]
struct ProgressState<'a> {
    proxy: ProgressProxy<'a>,
}

#[derive(Error, Debug)]
pub enum ProgressError {
    #[error("Progress error: {0}")]
    Error(#[from] ServiceError),
    #[error("D-Bus error: {0}")]
    DBusError(#[from] zbus::Error),
}

impl IntoResponse for ProgressError {
    fn into_response(self) -> Response {
        let body = json!({
            "error": self.to_string()
        });
        (StatusCode::BAD_REQUEST, Json(body)).into_response()
    }
}

async fn progress(State(state): State<ProgressState<'_>>) -> Result<Json<Progress>, ProgressError> {
    let proxy = state.proxy;
    let progress = Progress::from_proxy(&proxy).await?;
    Ok(Json(progress))
}

#[pin_project]
pub struct ProgressStream<'a> {
    #[pin]
    inner: PropertyStream<'a, (u32, String)>,
    proxy: ProgressProxy<'a>,
}

pub async fn progress_stream<'a>(
    dbus: zbus::Connection,
    destination: &'static str,
    path: &'static str,
) -> Result<Pin<Box<impl Stream<Item = Event> + Send>>, zbus::Error> {
    let proxy = build_progress_proxy(&dbus, destination, path).await?;
    Ok(Box::pin(ProgressStream::new(proxy).await))
}

impl<'a> ProgressStream<'a> {
    pub async fn new(proxy: ProgressProxy<'a>) -> Self {
        let stream = proxy.receive_current_step_changed().await;
        ProgressStream {
            inner: stream,
            proxy,
        }
    }
}

impl<'a> Stream for ProgressStream<'a> {
    type Item = Event;

    fn poll_next(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        let pinned = self.project();
        match pinned.inner.poll_next(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(_change) => match Progress::from_cached_proxy(&pinned.proxy) {
                Some(progress) => {
                    let event = Event::Progress {
                        progress,
                        service: pinned.proxy.destination().to_string(),
                    };
                    Poll::Ready(Some(event))
                }
                _ => Poll::Pending,
            },
        }
    }
}

async fn build_progress_proxy<'a>(
    dbus: &zbus::Connection,
    destination: &str,
    path: &str,
) -> Result<ProgressProxy<'a>, zbus::Error> {
    let proxy = ProgressProxy::builder(&dbus)
        .destination(destination.to_string())?
        .path(path.to_string())?
        .build()
        .await?;
    Ok(proxy)
}
