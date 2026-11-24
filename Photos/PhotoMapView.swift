import MapKit
import SwiftUI

struct PhotoMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // keyed per opening, so the map's content goes away with it
        if let state = model.map {
            PhotoMapScreen(state: state)
                .id(state.id)
        }
    }
}

private struct PhotoMapScreen: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.MapState
    @State private var content: PhotoMapContent?

    var body: some View {
        @Bindable var ui = model.ui
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            if let content {
                if content.isEmpty {
                    ContentUnavailableView(
                        "No photos with a location",
                        systemImage: "mappin.slash",
                        description: Text("None of the photos in this view have a location in Google Photos.")
                    )
                } else {
                    PhotoMapKitView(
                        content: content,
                        style: ui.mapStyle,
                        onOpen: { model.openLightbox(positions: $0) }
                    )
                    .ignoresSafeArea()
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }

            chrome(style: $ui.mapStyle)
        }
        .task { await load() }
    }

    private func chrome(style: Binding<PhotoMapStyle>) -> some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let content {
                        Text("With location: \(content.locatedCount) of \(content.totalCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)

                Spacer()

                Picker("Map style", selection: style) {
                    Text("Map").tag(PhotoMapStyle.standard)
                    Text("Satellite").tag(PhotoMapStyle.satellite)
                    Text("Hybrid").tag(PhotoMapStyle.hybrid)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button {
                    model.map = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                }
                .buttonStyle(.glass)
                // the lightbox opened from a pin owns Escape while it is up
                .keyboardShortcut(model.lightbox == nil ? .cancelAction : nil)
                .help("Close")
            }
            Spacer()
        }
        .padding(20)
    }

    private func load() async {
        let items = state.items
        let library = state.borrowsLibraryLocations ? model.library.items : []
        let built = await Task.detached(priority: .userInitiated) {
            PhotoMapBuilder.content(from: items, library: library)
        }.value
        guard !Task.isCancelled else { return }
        content = built
    }
}

private extension PhotoMapStyle {
    var configuration: MKMapConfiguration {
        switch self {
        case .standard: MKStandardMapConfiguration()
        case .satellite: MKImageryMapConfiguration()
        case .hybrid: MKHybridMapConfiguration()
        }
    }
}

// SwiftUI's Map cannot cluster annotations; MKMapView clusters the pins that still collide
// after PhotoMapContent picked the level of detail for the zoom
private struct PhotoMapKitView: NSViewRepresentable {
    let content: PhotoMapContent
    let style: PhotoMapStyle
    let onOpen: ([Int]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> PhotoMapNSView {
        let view = PhotoMapNSView()
        view.delegate = context.coordinator
        view.showsZoomControls = true
        view.showsScale = true
        // a rotated or tilted map's visibleMapRect is the bounding box of what it shows, which
        // the level of detail and the zoom-or-open decision would misread
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.nodeReuseID)
        view.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.clusterReuseID)
        if let bounds = content.bounds {
            view.fit(bounds)
        }
        return view
    }

    func updateNSView(_ view: PhotoMapNSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpen = onOpen
        if coordinator.style != style {
            coordinator.style = style
            view.preferredConfiguration = style.configuration
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let content: PhotoMapContent
        var onOpen: (([Int]) -> Void)?
        var style: PhotoMapStyle?
        private var shown: [PhotoMapNode.ID: PhotoNodeAnnotation] = [:]
        private var lastZoomed: Set<PhotoMapNode.ID> = []

        init(content: PhotoMapContent) {
            self.content = content
        }

        // only the level of detail that fits the zoom, and only around the visible region,
        // goes to MapKit: it creates a view for every annotation on screen
        func refresh(_ mapView: MKMapView) {
            guard mapView.bounds.width > 0 else { return }
            // from map points, not the region: a wide window can show more than the 360° of
            // longitude a span is capped at
            let degreesPerPoint = mapView.visibleMapRect.width / MKMapSize.world.width * 360 / mapView.bounds.width
            let level = PhotoMapContent.level(forPinDegrees: degreesPerPoint * PhotoPinView.side)
            let region = mapView.region
            let around = GeoRegion(
                center: GeoCoordinate(latitude: region.center.latitude, longitude: region.center.longitude),
                latitudeDelta: region.span.latitudeDelta * 1.5,
                longitudeDelta: region.span.longitudeDelta * 1.5
            )
            var wanted: [PhotoMapNode.ID: PhotoMapNode] = [:]
            for node in content.nodes(level: level, in: around) {
                wanted[node.id] = node
            }
            let stale = shown.filter { wanted[$0.key] == nil }
            for id in stale.keys {
                shown[id] = nil
            }
            mapView.removeAnnotations(Array(stale.values))
            var added: [PhotoNodeAnnotation] = []
            for (id, node) in wanted where shown[id] == nil {
                let annotation = PhotoNodeAnnotation(node)
                shown[id] = annotation
                added.append(annotation)
            }
            mapView.addAnnotations(added)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            refresh(mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            let isCluster = annotation is MKClusterAnnotation
            guard isCluster || annotation is PhotoNodeAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: isCluster ? PhotoPinView.clusterReuseID : PhotoPinView.nodeReuseID,
                for: annotation
            ) as? PhotoPinView
            view?.clusteringIdentifier = isCluster ? nil : PhotoPinView.clusteringID
            // clusters never hide; single pins give way to them
            view?.displayPriority = isCluster ? .required : .defaultHigh
            return view
        }

        // The deprecated view-based variant: the annotation-based one is unavailable on macOS
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            let nodes = PhotoNodeAnnotation.nodes(in: annotation).map(\.node)
            guard let bounds = GeoBounds.union(nodes.map(\.bounds)) else { return }
            let target = PhotoMapNSView.mapRect(for: bounds, minimumMeters: 300)
            let visible = mapView.visibleMapRect
            let zoom = min(visible.width / target.width, visible.height / target.height)
            let ids = Set(nodes.map(\.id))
            // a level-0 pin is one spot; a group that zooming would barely enlarge (photos on
            // both sides of a cell edge, metres apart), or that a zoom already failed to split,
            // opens as one, too
            if (nodes.count == 1 && nodes[0].level == 0) || zoom < 1.5 || ids == lastZoomed {
                lastZoomed = []
                onOpen?(content.photoPositions(of: nodes))
            } else {
                lastZoomed = ids
                mapView.setVisibleMapRect(target, edgePadding: PhotoMapNSView.padding, animated: true)
            }
        }
    }
}

private final class PhotoNodeAnnotation: NSObject, MKAnnotation {
    let node: PhotoMapNode
    let coordinate: CLLocationCoordinate2D

    init(_ node: PhotoMapNode) {
        self.node = node
        coordinate = CLLocationCoordinate2D(latitude: node.coordinate.latitude, longitude: node.coordinate.longitude)
    }

    static func nodes(in annotation: (any MKAnnotation)?) -> [PhotoNodeAnnotation] {
        if let cluster = annotation as? MKClusterAnnotation {
            return cluster.memberAnnotations.compactMap { $0 as? PhotoNodeAnnotation }
        }
        return (annotation as? PhotoNodeAnnotation).map { [$0] } ?? []
    }
}

private final class PhotoMapNSView: MKMapView {
    static let padding = NSEdgeInsets(top: 100, left: 60, bottom: 60, right: 60)
    private var pendingFit: MKMapRect?
    private weak var previousResponder: NSResponder?

    static func mapRect(for bounds: GeoBounds, minimumMeters: Double) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        var rect = MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
        let minimumSide = MKMapPointsPerMeterAtLatitude((bounds.minLatitude + bounds.maxLatitude) / 2) * minimumMeters
        rect = rect.insetBy(
            dx: -max(minimumSide - rect.width, 0) / 2,
            dy: -max(minimumSide - rect.height, 0) / 2
        )
        return rect
    }

    // The first fit waits for a real size: a visible rect set on a zero-sized map view lands
    // on the wrong zoom level
    func fit(_ bounds: GeoBounds) {
        pendingFit = Self.mapRect(for: bounds, minimumMeters: 2_000)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let rect = pendingFit, bounds.width > 0, bounds.height > 0 else { return }
        pendingFit = nil
        setVisibleMapRect(rect, edgePadding: Self.padding, animated: false)
        delegate?.mapView?(self, regionDidChangeAnimated: false)
    }

    // arrow keys must pan the map, not scroll the grid hidden under it; the grid gets its
    // focus back when the map closes
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if !((window.firstResponder as? NSView)?.isDescendant(of: self) ?? false) {
            previousResponder = window.firstResponder
        }
        window.makeFirstResponder(self)
    }

    // whatever holds the focus at close (the map, its picker, the close button) is going away
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, let previousResponder {
            window.makeFirstResponder(previousResponder)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

private final class PhotoPinView: MKMarkerAnnotationView {
    static let nodeReuseID = "photoNode"
    static let clusterReuseID = "photoCluster"
    static let clusteringID = "photos"
    // a marker's footprint: the level of detail keeps neighbouring pins about this far apart
    static let side: CGFloat = 40

    // MapKit can hand a cluster view a changed cluster without asking the delegate again,
    // so the content is read from the annotation here rather than in viewFor
    override func prepareForDisplay() {
        super.prepareForDisplay()
        let count = PhotoNodeAnnotation.nodes(in: annotation).reduce(0) { $0 + $1.node.count }
        if count == 1 {
            glyphText = nil
            glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        } else {
            glyphImage = nil
            glyphText = count.formatted(.number.notation(.compactName))
        }
        setAccessibilityLabel(photoCountText(count))
    }
}
