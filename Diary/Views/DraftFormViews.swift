import Foundation
import CoreLocation
import HealthKit
import MapKit
import SwiftUI
#if canImport(WeatherKit)
import WeatherKit
#endif
#if canImport(JournalingSuggestions)
import JournalingSuggestions
#endif

#if canImport(JournalingSuggestions)
/// Presents Apple's on-device Journaling Suggestions picker (photos, workouts,
/// places, …) and hands the chosen moment's text back to the composer. The
/// picker runs in a separate process and only returns what the user taps, never
/// the raw data set.
///
/// Requires the Apple-gated `com.apple.developer.journal.allowed` entitlement
/// and a physical device; the picker is empty in the Simulator.
struct JournalingMomentPicker: View {
    let onPick: (String) -> Void

    var body: some View {
        JournalingSuggestionsPicker {
            Label("Add a Moment", systemImage: "sparkles")
        } onCompletion: { suggestion in
            let title = suggestion.title
            guard !title.isEmpty else { return }
            await MainActor.run { onPick(title) }
        }
    }
}
#endif

struct ContextCaptureSection: View {
    @Binding var context: DiaryEntryContext
    let entryDate: Date

    @State private var isCapturing = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Context") {
            if context.isEmpty {
                Label("No context added", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            } else {
                ContextChipFlow(chips: context.summaryChips)
            }

            Button {
                Task {
                    await capture()
                }
            } label: {
                Label(isCapturing ? "Adding Context" : "Add Context", systemImage: "location.magnifyingglass")
            }
            .disabled(isCapturing)

            if !context.isEmpty {
                Button("Remove Context", systemImage: "xmark.circle", role: .destructive) {
                    context = .empty
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capture() async {
        isCapturing = true
        errorMessage = nil
        defer { isCapturing = false }

        let captured = await DiaryContextCaptureService.capture(for: entryDate)
        if captured.context.isEmpty {
            errorMessage = captured.message ?? "No context was available."
        } else {
            context = captured.context
            errorMessage = captured.message
        }
    }
}

struct ContextChipFlow: View {
    let chips: [String]

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Label(chip, systemImage: symbol(for: chip))
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                        .labelStyle(.titleAndIcon)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func symbol(for chip: String) -> String {
        let lowered = chip.lowercased()
        if lowered.contains("step") || lowered.contains("exercise") || lowered.contains("walk") || lowered.contains("run") {
            return "figure.walk"
        }
        if lowered.contains("cloud") || lowered.contains("rain") || lowered.contains("sun") || lowered.contains("snow") {
            return "cloud.sun"
        }
        return "mappin.and.ellipse"
    }
}

struct DiaryContextCaptureResult {
    var context: DiaryEntryContext
    var message: String?
}

enum DiaryContextCaptureService {
    @MainActor
    static func capture(for entryDate: Date) async -> DiaryContextCaptureResult {
        var context = DiaryEntryContext.empty
        context.source = "ios_direct"
        var failures: [String] = []

        var coordinateLocation: CLLocation?
        do {
            let captured = try await DiaryLocationCaptureService().capture()
            context.location = captured.context
            coordinateLocation = captured.location
        } catch {
            failures.append("Location unavailable")
        }

        if let coordinateLocation {
            do {
                context.weather = try await DiaryWeatherCaptureService.capture(location: coordinateLocation)
            } catch {
                failures.append("Weather unavailable")
            }
        }

        do {
            context.activity = try await DiaryActivityCaptureService.capture(for: entryDate)
        } catch {
            failures.append("Activity unavailable")
        }

        if context.location == nil && context.weather == nil && context.activity == nil {
            context.source = nil
        }

        return DiaryContextCaptureResult(
            context: context,
            message: failures.isEmpty ? nil : failures.joined(separator: ". ")
        )
    }
}

@MainActor
final class DiaryLocationCaptureService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func capture() async throws -> (context: DiaryLocationContext, location: CLLocation) {
        let location = try await requestLocation()
        let request = MKReverseGeocodingRequest(location: location)
        let mapItems = try? await request?.mapItems
        let label = Self.label(for: mapItems?.first) ?? Self.coordinateLabel(location)
        return (
            DiaryLocationContext(
                label: label,
                latitude: roundedCoordinate(location.coordinate.latitude),
                longitude: roundedCoordinate(location.coordinate.longitude),
                precision: "place",
                capturedAt: .now
            ),
            location
        )
    }

    private func requestLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw CLError(.denied)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                resume(with: .failure(CLError(.denied)))
            @unknown default:
                resume(with: .failure(CLError(.denied)))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            resume(with: .failure(CLError(.denied)))
        case .notDetermined:
            break
        @unknown default:
            resume(with: .failure(CLError(.denied)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            resume(with: .failure(CLError(.locationUnknown)))
            return
        }
        resume(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func roundedCoordinate(_ value: CLLocationDegrees) -> Double {
        (value * 100).rounded() / 100
    }

    private static func label(for mapItem: MKMapItem?) -> String? {
        guard let mapItem else { return nil }
        if let cityWithContext = mapItem.addressRepresentations?.cityWithContext,
           !cityWithContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cityWithContext
        }

        return mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func coordinateLabel(_ location: CLLocation) -> String {
        let latitude = location.coordinate.latitude.formatted(.number.precision(.fractionLength(2)))
        let longitude = location.coordinate.longitude.formatted(.number.precision(.fractionLength(2)))
        return "\(latitude), \(longitude)"
    }
}

enum DiaryWeatherCaptureService {
    static func capture(location: CLLocation) async throws -> DiaryWeatherContext? {
        #if canImport(WeatherKit)
        let weather = try await WeatherService.shared.weather(for: location)
        let current = weather.currentWeather
        return DiaryWeatherContext(
            provider: "apple_weather",
            condition: String(describing: current.condition),
            symbol: current.symbolName,
            temperatureF: current.temperature.converted(to: .fahrenheit).value,
            precipitation: nil,
            windMph: current.wind.speed.converted(to: .milesPerHour).value,
            attribution: "Weather",
            fetchedAt: .now
        )
        #else
        return nil
        #endif
    }
}

enum DiaryActivityCaptureService {
    static func capture(for date: Date) async throws -> DiaryActivityContext? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        let readTypes = healthReadTypes()
        try await requestAuthorization(store: store, readTypes: readTypes)

        let interval = Calendar.current.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
        let steps = try await quantitySum(store: store, identifier: .stepCount, unit: .count(), interval: interval).map { Int($0) }
        let exerciseMinutes = try await quantitySum(store: store, identifier: .appleExerciseTime, unit: .minute(), interval: interval).map { Int($0) }
        let activeEnergy = try await quantitySum(store: store, identifier: .activeEnergyBurned, unit: .kilocalorie(), interval: interval)
        let workouts = try await workouts(store: store, interval: interval)

        let context = DiaryActivityContext(
            steps: steps,
            exerciseMinutes: exerciseMinutes,
            activeEnergyKcal: activeEnergy,
            workouts: workouts,
            capturedAt: .now
        )

        return context.steps == nil
            && context.exerciseMinutes == nil
            && context.activeEnergyKcal == nil
            && context.workouts.isEmpty ? nil : context
    }

    private static func healthReadTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        for identifier in [HKQuantityTypeIdentifier.stepCount, .appleExerciseTime, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    private static func requestAuthorization(store: HKHealthStore, readTypes: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func quantitySum(
        store: HKHealthStore,
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        interval: DateInterval
    ) async throws -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [.strictStartDate])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
                }
            }
            store.execute(query)
        }
    }

    private static func workouts(store: HKHealthStore, interval: DateInterval) async throws -> [DiaryWorkoutContext] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout] ?? []).map { workout in
                    DiaryWorkoutContext(
                        type: workoutTypeName(workout.workoutActivityType),
                        startAt: workout.startDate,
                        endAt: workout.endDate,
                        durationMinutes: workout.duration / 60,
                        distanceMiles: workoutDistanceMiles(workout),
                        activeEnergyKcal: workoutActiveEnergyKcal(workout)
                    )
                }
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    private static func workoutActiveEnergyKcal(_ workout: HKWorkout) -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private static func workoutDistanceMiles(_ workout: HKWorkout) -> Double? {
        let identifier: HKQuantityTypeIdentifier = switch workout.workoutActivityType {
        case .cycling:
            .distanceCycling
        case .swimming:
            .distanceSwimming
        default:
            .distanceWalkingRunning
        }
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .mile())
    }

    private static func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        case .traditionalStrengthTraining: return "Strength"
        case .yoga: return "Yoga"
        default: return "Workout"
        }
    }
}

struct MarkdownEditorField: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .frame(minHeight: minHeight)
            .textInputAutocapitalization(.sentences)
            .overlay(alignment: .topLeading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write the memory...")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct SelectedMediaRows: View {
    let media: [MediaUploadDraft]
    let remove: (MediaUploadDraft) -> Void

    var body: some View {
        ForEach(media) { item in
            HStack(spacing: 12) {
                Label(item.filename, systemImage: item.contentType.hasPrefix("video/") ? "video" : "photo")
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(item.byteCount.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Remove", systemImage: "xmark.circle.fill") {
                    remove(item)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(item.filename)")
            }
        }
    }
}

struct SelectedMediaPreviewGrid: View {
    let media: [MediaUploadDraft]
    let remove: (MediaUploadDraft) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 180), spacing: 12)
    ]

    var body: some View {
        if !media.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(media) { item in
                    SelectedMediaPreviewTile(item: item, remove: remove)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Selected media")
        }
    }
}

private struct SelectedMediaPreviewTile: View {
    let item: MediaUploadDraft
    let remove: (MediaUploadDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                MediaDraftThumbnail(item: item)
                    .aspectRatio(1, contentMode: .fit)

                Button("Remove", systemImage: "xmark.circle.fill") {
                    remove(item)
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.white, .black.opacity(0.55))
                .padding(6)
                .accessibilityLabel("Remove \(item.filename)")
            }
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.caption)
                    .lineLimit(1)

                Label(item.byteCount.formatted(.byteCount(style: .file)), systemImage: item.isVideo ? "video" : "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MediaDraftThumbnail: View {
    let item: MediaUploadDraft

    var body: some View {
        ZStack {
            LocalMediaThumbnailView(
                url: item.fileURL,
                kind: item.isVideo ? .video : .image,
                maxPixelSize: 480,
                contentMode: .fill,
                placeholderSystemImage: item.isVideo ? "video" : "photo"
            )

            if item.isVideo {
                Label("Video", systemImage: "play.fill")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }
        }
    }
}

struct PendingChangeBadge: View {
    let change: PendingChange?

    var body: some View {
        if let change {
            Label(change.isFailed ? "Failed" : "Pending", systemImage: change.isFailed ? "exclamationmark.triangle.fill" : "clock")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(change.isFailed ? .red : .orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((change.isFailed ? Color.red : Color.orange).opacity(0.12), in: Capsule())
                .accessibilityLabel(change.isFailed ? "Sync failed" : "Pending sync")
        }
    }
}

private extension MediaUploadDraft {
    var isVideo: Bool {
        contentType.hasPrefix("video/")
    }
}
