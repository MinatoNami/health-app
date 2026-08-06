"""Rule-based safety, running before and after the model.

§7 of the integration notes is the whole argument for this file: do not rely on
the LLM to decide whether a situation may be concerning. A language model asked
"is 105 bpm resting worrying?" will produce a fluent answer either way, and
which way depends on phrasing. So the escalation level is decided here, by
rules, from reviewed public guidance — and the model is told what level it is
writing at rather than choosing one.

Two passes:

* **Pre-flight** turns the deterministic snapshot into an escalation level and a
  set of constraints the prompt carries. Reported symptoms outrank every
  measurement: "my chest hurts but my watch says I'm fine" must never resolve to
  reassurance.
* **Post-flight** re-reads what the model produced and blocks the specific
  failure modes §7 lists — diagnosis, medication advice, aggressive calorie
  restriction, treating missing data as normal, and claiming a wearable can rule
  out illness.

Thresholds here are deliberately wide and few. They exist to catch values that
public health guidance treats as worth a conversation with a clinician, not to
screen for conditions. Anything narrower would be a medical device.
"""

import re
from dataclasses import dataclass, field

# Escalation levels, weakest first.
LEVELS = ["informational", "coaching", "review_recommended", "urgent"]


def escalate(current: str, candidate: str) -> str:
    return candidate if LEVELS.index(candidate) > LEVELS.index(current) else current


@dataclass
class SafetyVerdict:
    level: str = "informational"
    # Plain-language reasons, shown to the user alongside the answer. Never
    # hidden: a system that quietly decides something is serious and then writes
    # a breezy answer is worse than one that says why it is being careful.
    reasons: list[str] = field(default_factory=list)
    # Instructions injected into the model's system prompt for this turn.
    constraints: list[str] = field(default_factory=list)
    # Set when the answer must not be shown as written.
    blocked: bool = False
    blocked_reason: str = ""

    def add(self, level: str, reason: str, constraint: str | None = None):
        self.level = escalate(self.level, level)
        if reason not in self.reasons:
            self.reasons.append(reason)
        if constraint and constraint not in self.constraints:
            self.constraints.append(constraint)

    def as_dict(self) -> dict:
        return {
            "level": self.level,
            "reasons": self.reasons,
            "blocked": self.blocked,
            "blocked_reason": self.blocked_reason,
        }


# --------------------------------------------------------------------------
# Symptoms
# --------------------------------------------------------------------------

# Phrases that describe something a person is feeling. Wearable data cannot
# rule any of these out, so their presence changes the level regardless of what
# the numbers say.
URGENT_SYMPTOMS = [
    (r"\bchest (pain|pressure|tightness|discomfort)\b", "chest pain or pressure"),
    (r"\bcan'?t breathe\b|\bstruggling to breathe\b|\bsevere(ly)? short(ness)? of breath\b",
     "severe breathlessness"),
    (r"\bfaint(ed|ing)?\b|\bpassed out\b|\bblack(ed)? out\b|\bsyncope\b", "fainting"),
    (r"\bcollaps(e|ed|ing)\b", "collapse"),
    (r"\bslurred speech\b|\bface (is )?droop", "stroke-type symptoms"),
    (r"\bcough(ing)? (up )?blood\b|\bblood in (my )?(stool|urine|vomit)\b", "bleeding"),
    (r"\bsuicid|\bkill myself\b|\bend my life\b|\bself.harm\b", "thoughts of self-harm"),
    (r"\bnumb(ness)? (in|on) (one|my left|my right) (side|arm|leg)\b", "one-sided numbness"),
]

REVIEW_SYMPTOMS = [
    (r"\bpalpitation|\bheart (is )?racing\b|\birregular heart\b", "palpitations"),
    (r"\bshort(ness)? of breath\b|\bbreathless\b", "breathlessness"),
    (r"\bdizz(y|iness)\b|\blight.?headed\b", "dizziness"),
    (r"\bswollen (ankle|leg|feet)|\bswelling in (my )?(ankle|leg|feet)", "swelling"),
    (r"\bfever(ish)?\b|\btemperature of\b", "fever"),
    # "really tired all week" is the phrasing people actually use, and a symptom
    # is a symptom however casually it is worded. Bare "tired" is deliberately
    # left out: "why am I tired?" is a normal coaching question, and attaching a
    # see-a-clinician banner to it would teach people to ignore the banner.
    (
        r"\bexhaust(ed|ion)\b|\bfatigue(d)?\b|\bno energy\b|\bwiped out\b|\bworn out\b|"
        r"\b(so|very|really|constantly|always|unusually|extremely|permanently) tired\b|"
        r"\btired (all|every|the whole) (the )?(time|week|day|month)\b",
        "persistent fatigue",
    ),
    (r"\bpain\b|\bhurts\b|\bache\b", "reported pain"),
    (r"\bnot eating\b|\blost weight without\b|\bunintentional weight loss\b",
     "unintentional weight change"),
]


def detect_symptoms(text: str) -> tuple[list[str], list[str]]:
    """Returns (urgent, review) symptom labels found in free text.

    Regex, not a model. A classifier that is 97% accurate is a classifier that
    misses chest pain three times in a hundred, and this list is short enough
    that literal matching is both auditable and sufficient.
    """
    lowered = (text or "").lower()
    urgent = [label for pattern, label in URGENT_SYMPTOMS if re.search(pattern, lowered)]
    review = [label for pattern, label in REVIEW_SYMPTOMS if re.search(pattern, lowered)]
    return urgent, review


# --------------------------------------------------------------------------
# Measurement thresholds
# --------------------------------------------------------------------------

# Wide bands drawn from ordinary public guidance, used only to decide whether to
# suggest a conversation with a clinician. Crossing one is never presented as a
# diagnosis, and a value inside the band is never presented as reassurance.
#
# Each entry: (metric, low, high, note). `None` disables that side.
THRESHOLDS = {
    "resting_heart_rate": (
        40, 100,
        "Resting heart rate consistently outside roughly 40–100 bpm is worth mentioning "
        "to a clinician. Trained athletes are often below 40 without any problem.",
    ),
    "oxygen_saturation": (
        92, None,
        "Blood-oxygen readings below about 92% are worth checking with a clinician — "
        "though wrist sensors are easily thrown off by fit, cold hands, and tattoos.",
    ),
    "respiratory_rate": (
        8, 25,
        "A resting respiratory rate persistently outside roughly 8–25 breaths per minute "
        "is worth raising with a clinician.",
    ),
}

# Sustained matters more than a single reading: sensors misfire, and one bad
# night is not a trend.
THRESHOLD_MIN_DAYS = 3


def check_measurements(snapshot: dict) -> list[dict]:
    """Threshold crossings in the deterministic snapshot.

    Only flags a metric whose confidence is at least moderate — a "low" average
    built from two readings is exactly the kind of number that should not
    trigger anything.
    """
    hits = []
    for comparison in snapshot.get("metrics", []):
        slug = comparison["metric_slug"]
        band = THRESHOLDS.get(slug)
        if not band:
            continue
        value = comparison["current"]["value"]
        if value is None:
            continue
        if comparison["confidence"] in ("insufficient", "low"):
            continue
        if comparison["current"]["valid_days"] < THRESHOLD_MIN_DAYS:
            continue

        low, high, note = band
        side = None
        if low is not None and value < low:
            side = "below"
        elif high is not None and value > high:
            side = "above"
        if side:
            hits.append(
                {
                    "metric_slug": slug,
                    "label": comparison["label"],
                    "value": value,
                    "unit": comparison["unit"],
                    "side": side,
                    "guidance": note,
                    "valid_days": comparison["current"]["valid_days"],
                }
            )
    return hits


# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------

# Questions about eating and drinking. Matched loosely on purpose: the cost of a
# false positive is four extra lines in a prompt, and the cost of a miss is an
# answer about food written without the rules that make one safe.
NUTRITION_QUESTION = re.compile(
    r"\b(eat|eats|eating|eaten|ate|food|foods|diet|dietary|meal|meals|snack|"
    r"calorie|calories|kcal|macro|macros|protein|carb|carbs|carbohydrate|fat|"
    r"nutrition|nutritional|nutrient|fibre|fiber|sugar|sodium|salt|hydration|"
    r"hydrated|drink|drinking|water|caffeine|breakfast|lunch|dinner)\b",
    re.IGNORECASE,
)

# Extra rules for any answer that touches nutrition. The first three exist
# because a food log is the only signal in this system a person writes
# themselves; the fourth because "am I eating enough" is a clinical question
# wearing a wellness question's clothes, and a food diary cannot answer it.
NUTRITION_CONSTRAINTS = [
    'Nutrition figures are self-reported — what was typed into a food app, not what was '
    'eaten and not a measurement of it. Write "logged" rather than "ate" or "consumed".',
    "Never state a number as an amount this person should eat or drink. No calorie "
    "targets, no macronutrient targets, no intake goals, and no comparison against a "
    "recommended allowance or a population average, in any units.",
    "Days with no food log are unknown. Never average them in, never call them light "
    "days, and never total a window as though every day in it was logged.",
    "Logged intake minus estimated energy burned is the difference between two estimates, "
    "one of them a formula. Never call it a deficit or a surplus, and never turn it into a "
    "rate of weight change. If measured weight is given alongside it, that is the stronger "
    "evidence and should lead.",
    "Whether someone is eating enough cannot be established from a food diary. Say what "
    "was logged and over how many days, compare it only with their own logged baseline "
    "and their estimated energy burned, and say that judging adequacy needs a dietitian "
    "or doctor who can weigh what this data does not contain.",
]

BASE_CONSTRAINTS = [
    "Use only the figures returned by the tools. Never state a measurement, date, or "
    "symptom that did not come from a tool result.",
    "Compare against the person's own baseline, and name the periods and units you used.",
    "Do not diagnose, name a condition as the cause, or suggest starting, stopping, or "
    "changing any medication.",
    "Never say that wearable data rules out illness, and never tell someone to ignore how "
    "they feel because a reading looks normal.",
    "Treat missing days as missing. Never describe a gap in the data as a normal value.",
    "Describe a relationship between two metrics as an association, never as a cause.",
    "Present energy-burned figures as estimates, never as exact.",
]


def preflight(question: str, snapshot: dict, context: str = "") -> SafetyVerdict:
    """Decides the level and the constraints *before* the model is asked."""
    verdict = SafetyVerdict()
    verdict.constraints.extend(BASE_CONSTRAINTS)

    urgent, review = detect_symptoms(f"{question}\n{context}")

    if urgent:
        verdict.add(
            "urgent",
            "You described " + ", ".join(urgent) + ".",
            "The person has described a symptom that needs prompt medical attention. Open "
            "the answer by saying so plainly and telling them to seek urgent medical care "
            "or call their local emergency number. Do not analyse the wearable data as "
            "though it settles the question, and do not offer reassurance from it.",
        )
        verdict.add(
            "urgent",
            "Wearable measurements cannot rule out a cause for that, whatever they show.",
        )

    if review:
        verdict.add(
            "review_recommended",
            "You mentioned " + ", ".join(review) + ".",
            "The person has reported a symptom. Prioritise the symptom over the "
            "measurements: say clearly that this data cannot establish a cause, and "
            "recommend review by a qualified healthcare professional if it persists or "
            "worsens.",
        )

    for hit in check_measurements(snapshot):
        verdict.add(
            "review_recommended",
            f"{hit['label']} averaged {hit['value']} {hit['unit']} over "
            f"{hit['valid_days']} day(s), {hit['side']} the usual range.",
            f"{hit['label']} is {hit['side']} the usual range ({hit['value']} {hit['unit']}). "
            f"{hit['guidance']} Mention it factually, without naming a cause.",
        )

    food = snapshot.get("nutrition") or {}
    if food or NUTRITION_QUESTION.search(f"{question}\n{context}"):
        for constraint in NUTRITION_CONSTRAINTS:
            if constraint not in verdict.constraints:
                verdict.constraints.append(constraint)

    if food and food.get("confidence") in ("insufficient", "low"):
        verdict.add(
            "informational",
            f"Your food log covers {food.get('days_fully_logged', 0)} of the last "
            f"{food.get('window_days', 0)} days, so anything about intake is partial.",
            "The food log covers only part of this window. Lead with how many days were "
            "logged before quoting any average from it, and do not describe intake over "
            "the whole period.",
        )
    elif not food and NUTRITION_QUESTION.search(question or ""):
        # Asked about food with no food logged. Weight and energy burned are the
        # nearest things to hand and neither is a record of eating, so say so
        # rather than letting an answer be assembled out of them.
        verdict.add(
            "informational",
            "No food or drink has been logged, so there is nothing here about what you eat.",
            "Nothing has been logged about food or drink. Say that plainly and do not infer "
            "intake from weight, energy burned, or any other metric.",
        )

    stale = snapshot.get("metrics_not_syncing") or []
    if stale:
        names = ", ".join(
            f"{item['label']} (last recorded {item['last_recorded_at'][:10]})"
            if item.get("last_recorded_at")
            else item["label"]
            for item in stale
        )
        verdict.add(
            "informational",
            f"No recent data for: {names}.",
            f"These metrics have stopped arriving: {names}. Say the data is missing and "
            "when it stopped. Never describe a gap as a zero or as a change in behaviour — "
            "a watch that was not worn is not a night without sleep.",
        )

    confidence = snapshot.get("overall_confidence", "insufficient")
    if confidence in ("insufficient", "low"):
        verdict.add(
            "informational",
            f"Data coverage for this period is {confidence}, so conclusions are tentative.",
            "Data coverage is weak. Say so explicitly, keep every claim tentative, and do "
            "not describe a trend the coverage cannot support.",
        )

    if verdict.level in ("informational", "coaching"):
        verdict.add(
            "coaching",
            "",
            "Offer at most three specific, realistic wellness actions, each with a reason "
            "and a timeframe.",
        )
        verdict.reasons = [r for r in verdict.reasons if r]

    return verdict


# --------------------------------------------------------------------------
# Post-flight
# --------------------------------------------------------------------------

# Rules that mean the answer has crossed from wellness into clinical claims.
#
# Each carries an optional `unless_preceded_by`, checked in a short window
# before the match. That guard is not a nicety: "this data cannot rule out an
# underlying illness" is the sentence the system prompt explicitly asks for, and
# a pattern that only looks for "rule out illness" blocks the correct answer and
# lets nothing useful through. Negation and conditionals reverse the meaning of
# almost every phrase on this list.
#
# Deliberately narrow overall — a broad "heart" or "risk" filter would trip on
# ordinary sentences and train people to ignore the warning.

NEGATION = (
    r"\b(?:not|n'?t|cannot|can'?t|never|unable to|does not|do not|will not|won'?t|"
    r"isn'?t|aren'?t|doesn'?t|don'?t|rather than|instead of)\b"
)
CONDITIONAL = r"\b(?:if|whether|unless|should you|in case)\b"
GUARD_WINDOW = 45


@dataclass(frozen=True)
class Rule:
    pattern: str
    description: str
    # Matches in this window before the hit mean the phrase was negated or
    # hypothetical, so the rule does not apply.
    unless_preceded_by: str | None = None

    def hits(self, text: str) -> bool:
        for match in re.finditer(self.pattern, text):
            if self.unless_preceded_by:
                window = text[max(0, match.start() - GUARD_WINDOW) : match.start()]
                if re.search(self.unless_preceded_by, window):
                    continue
            return True
        return False


PROHIBITED = [
    Rule(
        # `(?:\w+ ){0,2}` matters: models write "you probably have sleep apnea",
        # not "you have apnea". Anchoring tight to the condition word missed the
        # phrasing that actually occurs.
        r"\byou (?:probably |likely |may |might |could )?have (?:a |an )?(?:\w+ ){0,2}"
        r"(?:condition|disease|infection|apnoea|apnea|diabetes|hypertension|anaemia|anemia|"
        r"arrhythmia|afib|atrial fibrillation|covid|flu|thyroid|insomnia)\b",
        "names a medical condition as something the person has",
        unless_preceded_by=f"(?:{NEGATION}|{CONDITIONAL})",
    ),
    Rule(
        r"\b(?:you (?:should|could|can|might want to) )?(?:start|stop|increase|decrease|reduce|"
        r"double|halve|adjust|come off|taper)(?: taking| your)? (?:medication|meds|dose|dosage|"
        r"tablets|pills|statins?|beta.?blockers?|insulin|antidepressants?)",
        "gives medication advice",
        unless_preceded_by=NEGATION,
    ),
    Rule(
        r"\brules?\s+out\b(?:.{0,40}?\b(?:illness|infection|disease|condition|problem)\b)"
        r"|\b(?:illness|infection|disease|condition)\b.{0,30}?\bruled\s+out\b",
        "claims the data can rule out illness",
        # "cannot rule out" is the required phrasing, not a violation.
        unless_preceded_by=NEGATION,
    ),
    Rule(
        r"\b(?:ignore|don'?t worry about|disregard) (?:the |your |any )?(?:symptom|pain|how you feel)",
        "tells the person to ignore a symptom",
        unless_preceded_by=NEGATION,
    ),
    Rule(
        # The number does not always follow the word "calories" — "cut calories
        # to below 900 a day" puts it after two other words — so match the pair
        # within a short span rather than adjacently.
        r"\bcalories?\b.{0,25}?\b(?:below|under|to|max(?:imum)? of)\s*(?:below\s*|under\s*)?"
        r"(?:[1-9]\d{2}|1[0-2]\d{2})\b"
        r"|\b(?:under|below|max(?:imum)? of) ?1[0-2]\d{2} ?(?:kcal|calories)"
        r"|\bfast(?:ing)? for (?:2[4-9]|[3-9]\d|\d{3,}) hours",
        "recommends an unsafely restrictive diet",
        unless_preceded_by=NEGATION,
    ),
    Rule(
        r"\b(?:this (?:proves|shows) that|because of this,? your)\b.{0,40}\bcaus(?:ed|es|ing)\b",
        "presents a correlation as a cause",
        unless_preceded_by=NEGATION,
    ),
    Rule(
        # Prescribing an intake, as opposed to reporting one. The rule above
        # catches only the unsafely restrictive end; this catches the ordinary
        # target, which is still nutritional prescription from a system that
        # will not name a condition.
        #
        # The gate is a prescriptive verb *and* a number *and* a unit food is
        # measured in. "You logged 2,430 kcal a day" has the last two and must
        # survive — an answer that cannot quote what was logged is not a safer
        # answer, just a useless one.
        rf"\b(?:aim(?:ing)? (?:for|at)|shoot for|a target of|"
        rf"should (?:eat|consume|drink|get|have|hit|be eating|be getting)|"
        rf"try to (?:eat|consume|drink|get|hit|reach)|"
        rf"(?:keep|hold) (?:it|them|your intake|your calories) (?:to|at|under|below)|"
        rf"(?:increase|raise|cut|reduce|drop) (?:it|them|your intake|your calories) to)"
        rf"\b[^.]{{0,40}}?\b\d[\d,.]*\s*"
        rf"(?:kcal|calories|cal|g|grams?|mg|mcg|ml|millilitres?|milliliters?|litres?|liters?)\b",
        "sets a target for what to eat or drink",
        unless_preceded_by=NEGATION,
    ),
]

# Softer signals: allowed, but the answer must carry the professional-review
# flag if it says any of this.
REVIEW_TRIGGERS = [
    r"\b(see|speak(ing)? (to|with)|talk(ing)? (to|with)|consult|contact|raise (it|this) with)\s+"
    r"(a|an|your)?\s*(doctor|gp\b|clinician|physician|nurse|healthcare provider)",
    r"\bmedical (attention|advice|review)\b",
    r"\bhealthcare professional\b",
]


def _flatten(insight: dict) -> str:
    """Every piece of prose the user will actually read.

    Checking only the summary would let a prohibited claim through in an
    observation or an action, which is where the specific advice lives.
    """
    parts = [str(insight.get("summary") or "")]
    for observation in insight.get("observations") or []:
        parts.append(str(observation.get("statement") or ""))
        parts.append(str(observation.get("evidence") or ""))
    for action in insight.get("actions") or []:
        parts.append(str(action.get("action") or ""))
        parts.append(str(action.get("reason") or ""))
    parts.extend(str(item) for item in (insight.get("limitations") or []))
    parts.append(str(insight.get("professional_review_reason") or ""))
    return "\n".join(parts)


def postflight(insight: dict, verdict: SafetyVerdict) -> SafetyVerdict:
    """Re-reads the model's answer and blocks the failure modes §7 lists.

    Blocking rather than editing: silently deleting a sentence leaves an answer
    that reads as complete but no longer says what the model concluded. Refusing
    to show it and explaining why is honest, and the deterministic snapshot is
    still there to read.
    """
    text = _flatten(insight).lower()

    for rule in PROHIBITED:
        if rule.hits(text):
            verdict.blocked = True
            verdict.blocked_reason = (
                f"The generated answer {rule.description}, which this system does not allow. "
                "The measured summary below is unaffected."
            )
            verdict.level = escalate(verdict.level, "review_recommended")
            return verdict

    if verdict.level == "urgent" and not insight.get("professional_review_recommended"):
        # The model was told to escalate and did not. Rather than trust the
        # prose, set the flag here so the UI shows the urgent banner regardless.
        insight["professional_review_recommended"] = True
        insight["professional_review_reason"] = (
            insight.get("professional_review_reason")
            or "You described a symptom that needs prompt medical attention."
        )

    if any(re.search(pattern, text) for pattern in REVIEW_TRIGGERS):
        insight["professional_review_recommended"] = True

    return verdict


URGENT_NOTICE = (
    "What you have described needs prompt medical attention. Please contact urgent care "
    "or your local emergency number now. Data from a watch or phone cannot rule out a "
    "serious cause, and normal-looking readings are not a reason to wait."
)
