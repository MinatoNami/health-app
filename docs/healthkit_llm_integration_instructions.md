# Linking HealthKit Data to an LLM for Personal Health Insights

## Overview

A strong implementation should not connect an LLM directly to thousands of raw HealthKit records.

Instead, use this flow:

**HealthKit → validated database → deterministic summaries → controlled LLM tools → safe explanations and recommendations**

The LLM should explain prepared health summaries, identify trends, highlight limitations, and suggest realistic wellness actions. It should not calculate directly from large volumes of raw samples or make medical diagnoses.

---

## Recommended Architecture

1. Apple Health and Apple Watch collect health and fitness data.
2. A native iOS app reads selected data through HealthKit.
3. The app uploads authorized data to an authenticated backend.
4. The backend stores raw records and calculated summaries.
5. A health analysis service calculates trends, baselines, and data quality.
6. The LLM accesses only controlled, read-only health summary tools.
7. The app presents explanations, recommendations, confidence, and limitations.

---

## 1. Build a Native iOS HealthKit Collector

Use a native iOS application built with SwiftUI and HealthKit.

For the first version, consider collecting:

- Steps
- Walking and running distance
- Active energy
- Exercise minutes
- Workouts
- Heart rate
- Resting heart rate
- Walking heart rate average
- Heart-rate variability
- Respiratory rate
- Sleep sessions
- Weight
- Body-fat percentage, when available
- Blood oxygen, when available

Request only the permissions required for the features the user enables. HealthKit authorization is granted separately for each data type, and users may deny individual permissions.

The application should clearly explain why each health-data permission is required.

### Data Synchronization

For the initial synchronization:

1. Import a sensible historical period, such as the previous 30 to 90 days.
2. Upload the relevant samples to the backend.
3. Save the HealthKit synchronization position so future imports can be incremental.

For later synchronizations:

- Detect when HealthKit data changes.
- Retrieve only inserted, updated, or deleted records.
- Use background delivery where appropriate.
- Run a catch-up synchronization whenever the app opens.

Do not assume HealthKit background delivery is real-time. iOS decides when an application is allowed to run in the background.

---

## 2. Store the Data in PostgreSQL

A suitable personal or early-stage setup is:

- FastAPI or Django
- PostgreSQL
- Optional TimescaleDB for advanced time-series workloads
- Docker Compose on a home server
- Tailscale for private network access
- A standard authentication system using secure tokens or passkeys

Plain PostgreSQL is sufficient for an MVP.

### Raw Health Records

Store details such as:

- Internal record identifier
- User identifier
- Original HealthKit sample identifier
- Metric type
- Start time
- End time
- Numeric or category value
- Measurement unit
- Source application
- Source device
- Relevant metadata
- Import timestamp

The original HealthKit identifier should be unique for each user so repeated synchronizations do not create duplicate records.

### Daily Summaries

Maintain a separate daily summary for values such as:

- Steps
- Active energy
- Exercise minutes
- Sleep duration
- Resting heart rate
- Average heart rate
- Heart-rate variability
- Respiratory rate
- Weight
- Data completeness

HealthKit records may be edited or deleted, so the backend must reconcile changes instead of treating every uploaded value as permanent.

---

## 3. Calculate Health Indicators Outside the LLM

The backend should convert raw records into a structured health snapshot before sending anything to the LLM.

A health snapshot may contain:

- Reporting period
- Daily activity average
- Change from the previous period
- Average sleep duration
- Typical bedtime and wake time
- Resting heart rate trend
- Heart-rate variability trend
- Latest weight
- Weekly weight change
- Number of valid days
- Missing or incomplete data
- Known measurement limitations

Use regular application logic for calculations such as:

- Seven-day moving averages
- Twenty-eight-day moving averages
- Week-over-week changes
- Differences from personal baselines
- Sleep consistency
- Workout frequency
- Activity streaks
- Weight trends
- Data-completeness scores
- Basic anomaly detection

This approach is more reliable than asking the LLM to calculate directly from raw database rows.

---

## 4. Use Personal Baselines

Many wearable measurements are more useful when compared against the user’s normal range rather than only against population averages.

A useful approach is:

- Calculate the baseline from the previous 28 valid days.
- Calculate the current value from the previous 7 valid days.
- Compare the current value with the baseline.
- Record how many valid days were available.
- Avoid firm conclusions when data coverage is low.

For example, the system may report that resting heart rate is above the user’s recent personal baseline without claiming a medical cause.

---

## 5. Give the LLM Read-Only Tools

Do not give the LLM database credentials or unrestricted SQL access.

Expose a limited set of backend functions such as:

- Retrieve a health overview for a period
- Retrieve a trend for a specific metric
- Compare two periods
- Retrieve recent workouts
- Retrieve a sleep summary
- Retrieve a data-quality report
- Retrieve the user’s goals

Each tool should return structured values including:

- Metric name
- Unit
- Current value
- Baseline value
- Absolute or percentage change
- Number of valid data days
- Confidence or data-quality classification

The backend must validate every request and ensure the authenticated user can access only their own records.

A vector database is generally unnecessary for numeric HealthKit data. A normal relational or time-series database with controlled query tools is usually more appropriate.

---

## 6. Separate Different Types of Output

The application should clearly distinguish between three categories.

### Descriptive Insights

These explain what changed.

Example:

> Your average sleep duration was lower this week than during your recent baseline period.

### Wellness Coaching

These suggest realistic actions.

Example:

> Try moving bedtime slightly earlier for one week and check whether total sleep duration improves.

### Clinical Questions

The application should not diagnose medical conditions from consumer wearable data.

For clinical questions, the application should explain that the data alone cannot determine a cause and that persistent or concerning changes may need review by a qualified healthcare professional.

This distinction should appear in both the user interface and the LLM instructions.

---

## 7. Add a Deterministic Safety Layer

Do not rely entirely on the LLM to determine whether a situation may be concerning.

Create a rule-based safety layer that runs before and after the LLM.

The safety layer should consider:

- Whether the measurement is valid
- How many samples are available
- Whether the data was entered manually
- Device and source reliability
- How long a trend has continued
- Relevant user-entered context
- Whether the user reports symptoms

Possible output levels may include:

- Informational
- Coaching
- Review recommended
- Urgent

For potentially serious situations, use carefully reviewed health guidance rather than allowing the model to invent thresholds.

The system should prevent the LLM from:

- Diagnosing diseases
- Recommending medication changes
- Giving unsafe or excessively restrictive diet advice
- Treating missing data as normal data
- Claiming that correlation proves causation
- Presenting calorie expenditure estimates as exact
- Telling users to ignore symptoms because wearable readings appear normal
- Claiming wearable data can rule out illness

When symptoms are reported, the system should prioritize the symptoms over apparently normal wearable measurements.

---

## 8. Protect User Privacy

Health data is highly sensitive and should receive stronger protection than ordinary application data.

At minimum:

- Encrypt all network traffic
- Encrypt databases and backups
- Separate identity information from health records where practical
- Avoid storing raw health payloads in application logs
- Remove health data from crash reports and error trackers
- Provide data export
- Provide permanent account and data deletion
- Record consent versions
- Allow users to disable cloud-based processing
- Clearly identify which LLM provider receives data
- Send summaries instead of full raw histories whenever possible
- Avoid retaining prompts and model responses indefinitely
- Never use health data for advertising
- Never sell health information to data brokers or resellers

A privacy policy should clearly state:

- Which HealthKit data is collected
- Why it is collected
- Where it is stored
- How long it is retained
- Whether it is sent to an external model provider
- How the user can delete it
- Whether the data is used for model training

### Optional Privacy Modes

Consider offering two modes.

#### Private Local Mode

- HealthKit data remains on the device.
- Summaries are calculated locally.
- A local model may be used.
- No health information is sent to a cloud service.

#### Cloud Insights Mode

- Selected summaries are sent to the backend.
- The LLM receives only the information required for the question.
- Explicit user consent is required.
- The user can disable the feature at any time.

---

## 9. Recommended MVP Technology Stack

A practical stack is:

### iOS Application

- SwiftUI
- HealthKit
- Secure credential storage
- Background and foreground synchronization

### Private Network

- Tailscale
- HTTPS between the phone and backend

### Backend

- FastAPI or Django
- PostgreSQL
- SQLAlchemy or Django ORM
- Database migrations
- Optional Redis for jobs and caching

### Analysis Layer

- Scheduled daily aggregation
- Personal baseline calculations
- Trend detection
- Data-quality scoring
- Rule-based safety checks

### LLM Layer

- Tool-calling model
- Read-only health tools
- Structured model responses
- Strict wellness and medical-safety instructions

### Application Screens

- Today
- Trends
- Ask My Health
- Goals
- Data Sources
- Privacy and Consent

---

## 10. Suggested MVP Development Phases

### Phase 1: Health Data Pipeline

Start with:

- Steps
- Sleep
- Resting heart rate
- Workouts
- Weight

Implement:

- HealthKit permissions
- Initial historical import
- Incremental synchronization
- Authenticated batch upload
- Deduplication
- Deletion handling
- Daily summaries

### Phase 2: Health Dashboard

Display:

- Current seven-day summary
- Comparison with the previous four weeks
- Personal baseline
- Data-completeness indicators
- Trend charts
- Last successful synchronization

### Phase 3: LLM Questions and Answers

Support questions such as:

- How has my sleep changed this month?
- Am I becoming more or less active?
- What might be contributing to my tiredness?
- What are three realistic goals for next week?
- Did my resting heart rate change after I started exercising?
- Is there enough data to identify a trend?
- Which area should I focus on first?

Every answer should show:

- The observation
- The period examined
- Supporting measurements
- Confidence level
- Data limitations
- Recommended next steps

### Phase 4: Proactive Insights

Add:

- Weekly health reviews
- Meaningful trend notifications
- Questions that request context before drawing conclusions
- User feedback on whether an insight was useful
- Goal progress summaries
- Detection of missing or unreliable data

Avoid sending frequent alerts for small or uncertain changes.

---

## 11. LLM Behaviour Requirements

The model should be instructed to:

- Use only data returned by approved tools
- Never invent measurements, dates, symptoms, or context
- Distinguish observations from possible explanations
- Compare against the user’s personal baseline
- State when data coverage is insufficient
- Report measurement units and time periods
- Provide no more than a small number of practical recommendations
- Use cautious and clear language
- Explain uncertainty
- Avoid diagnoses
- Avoid medication advice
- Avoid replacing professional care
- Avoid claiming consumer wearable data can rule out illness
- Prioritize reported symptoms over wearable readings

---

## 12. Structured Insight Format

Each model response should be converted into a predictable structure containing:

- Plain-language summary
- List of observations
- Evidence for each observation
- Confidence level
- Recommended actions
- Reason for each action
- Suggested timeframe
- Data limitations
- Whether professional review may be appropriate
- Reason for recommending professional review

Structured responses make the output easier to validate, store, display, and audit.

---

## 13. Data Quality Considerations

HealthKit data may be incomplete or misleading because of:

- The Apple Watch not being worn
- Loose device fit
- Low battery
- Multiple devices recording the same metric
- Manual data entry
- Delayed synchronization
- Different source applications
- Missing sleep records
- Workouts recorded without heart rate
- Changes in device model or sensor behaviour

Every summary should include data-quality information.

The system should avoid comparing two periods unless both have sufficient coverage.

It should also identify the source of measurements when relevant and avoid mixing incompatible measurement methods without explanation.

---

## 14. Main Recommendation

Begin with five high-value signals:

- Sleep duration and consistency
- Daily steps
- Workouts and exercise minutes
- Resting heart rate
- Weight trend

These provide enough information for useful wellness coaching without making the first version overly complex.

Add heart-rate variability, respiratory rate, blood oxygen, and other measurements only after the synchronization, data-quality, safety, and interpretation systems are reliable.

The safest and most effective design is:

**HealthKit → validated storage → deterministic health summaries → controlled LLM access → cautious explanations and practical next steps**
