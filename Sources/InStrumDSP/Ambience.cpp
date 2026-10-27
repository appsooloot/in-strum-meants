// Ambience: placeholder until the generators land (Task 7).
#include "include/InStrumDSP.h"
#include <algorithm>

struct ISDAmbience { int unused; };

extern "C" {
ISDAmbience *isd_ambience_create(double, int, uint64_t) { return new ISDAmbience(); }
void isd_ambience_destroy(ISDAmbience *a) { delete a; }
void isd_ambience_set_level(ISDAmbience *, ISDAmbienceSource, float) {}
void isd_ambience_set_closeness(ISDAmbience *, float) {}
void isd_ambience_set_activity(ISDAmbience *, float) {}
void isd_ambience_set_night_cool(ISDAmbience *, float) {}
void isd_ambience_set_density(ISDAmbience *, float) {}
void isd_ambience_trigger_thunder(ISDAmbience *, float) {}
void isd_ambience_render(ISDAmbience *, float *l, float *r, int n) { std::fill(l, l + n, 0.f); std::fill(r, r + n, 0.f); }
}
