#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdbool.h>
#include <unistd.h>

#define MY_CXT_KEY "Demo::XS::_guts" XS_VERSION

#define DEFERRED_CLASS "Demo::XS::Deferred"
#define DEFERRED_CLASS_TYPE Demo__XS__Deferred

#define PROMISE_CLASS "Demo::XS::Promise"

#ifdef PL_phase
#define PXS_IS_GLOBAL_DESTRUCTION PL_phase == PERL_PHASE_DESTRUCT
#else
#define PXS_IS_GLOBAL_DESTRUCTION PL_dirty
#endif

typedef struct xspr_promise_s xspr_promise_t;

typedef enum {
    XSPR_STATE_NONE,
    XSPR_STATE_PENDING,
    XSPR_STATE_FINISHED,
} xspr_promise_state_t;

struct xspr_promise_s {
    xspr_promise_state_t state;
    void* unhandled_rejection;
    int refs;
};

xspr_promise_t* xspr_promise_new(pTHX);

typedef struct {
    HV* pxs_stash;
    HV* pxs_deferred_stash;
} my_cxt_t;

typedef struct {
    xspr_promise_t* promise;
} DEFERRED_CLASS_TYPE;

START_MY_CXT

/* Creates a new promise. It's that simple. */
xspr_promise_t* xspr_promise_new(pTHX)
{
    xspr_promise_t* promise;
    Newxz(promise, 1, xspr_promise_t);
    promise->refs = 1;
    promise->state = XSPR_STATE_PENDING;
    promise->unhandled_rejection = NULL;
    return promise;
}

DEFERRED_CLASS_TYPE* _get_deferred_from_sv(pTHX_ SV *self_sv) {
    SV *referent = SvRV(self_sv);
    return INT2PTR(DEFERRED_CLASS_TYPE*, SvUV(referent));
}

SV* _ptr_to_svrv(pTHX_ void* ptr, HV* stash) {
    SV* referent = newSVuv( PTR2UV(ptr) );
    SV* retval = newRV_noinc(referent);
    sv_bless(retval, stash);

    return retval;
}

static inline xspr_promise_t* create_promise(pTHX) {
    xspr_promise_t* promise = xspr_promise_new(aTHX);

    return promise;
}

//----------------------------------------------------------------------

MODULE = Demo::XS     PACKAGE = Demo::XS

BOOT:
{
    MY_CXT_INIT;

    MY_CXT.pxs_stash = gv_stashpv(PROMISE_CLASS, FALSE);
    MY_CXT.pxs_deferred_stash = gv_stashpv(DEFERRED_CLASS, FALSE);
}

#----------------------------------------------------------------------

MODULE = Demo::XS     PACKAGE = Demo::XS::Deferred

SV *
create()
    CODE:
        dMY_CXT;

        DEFERRED_CLASS_TYPE* deferred_ptr;
        Newxz(deferred_ptr, 1, DEFERRED_CLASS_TYPE);

        xspr_promise_t* promise = create_promise(aTHX);

        deferred_ptr->promise = promise;

        RETVAL = _ptr_to_svrv(aTHX_ deferred_ptr, MY_CXT.pxs_deferred_stash);
    OUTPUT:
        RETVAL

void
DESTROY(SV *self_sv)
    CODE:
        DEFERRED_CLASS_TYPE* self = _get_deferred_from_sv(aTHX_ self_sv);

        fprintf(stderr, "before free promise\n");
        Safefree(self->promise);
        fprintf(stderr, "after free promise\n");
        Safefree(self);
