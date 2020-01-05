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

typedef struct xspr_callback_s xspr_callback_t;
typedef struct xspr_promise_s xspr_promise_t;
typedef struct xspr_result_s xspr_result_t;
typedef struct xspr_callback_queue_s xspr_callback_queue_t;

typedef enum {
    XSPR_STATE_NONE,
    XSPR_STATE_PENDING,
    XSPR_STATE_FINISHED,
} xspr_promise_state_t;

typedef enum {
    XSPR_RESULT_NONE,
    XSPR_RESULT_RESOLVED,
    XSPR_RESULT_REJECTED,
    XSPR_RESULT_BOTH
} xspr_result_state_t;

typedef enum {
    XSPR_CALLBACK_PERL,
    XSPR_CALLBACK_FINALLY,
    XSPR_CALLBACK_CHAIN
} xspr_callback_type_t;

struct xspr_callback_s {
    xspr_callback_type_t type;
    union {
        struct {
            SV* on_resolve;
            SV* on_reject;
            xspr_promise_t* next;
        } perl;
        struct {
            SV* on_finally;
            xspr_promise_t* next;
        } finally;
        xspr_promise_t* chain;
    };
};

struct xspr_result_s {
    xspr_result_state_t state;
    SV** results;
    int count;
    int refs;
};

struct xspr_promise_s {
    xspr_promise_state_t state;
    pid_t detect_leak_pid;
    xspr_result_t* unhandled_rejection;
    int refs;
    union {
        struct {
            xspr_callback_t** callbacks;
            int callbacks_count;
        } pending;
        struct {
            xspr_result_t *result;
        } finished;
    };
};

struct xspr_callback_queue_s {
    xspr_promise_t* origin;
    xspr_callback_t* callback;
    xspr_callback_queue_t* next;
};

void xspr_callback_process(pTHX_ xspr_callback_t* callback, xspr_promise_t* origin);
void xspr_callback_free(pTHX_ xspr_callback_t* callback);

xspr_promise_t* xspr_promise_new(pTHX);
void xspr_promise_then(pTHX_ xspr_promise_t* promise, xspr_callback_t* callback);
void xspr_promise_finish(pTHX_ xspr_promise_t* promise, xspr_result_t *result);
void xspr_promise_decref(pTHX_ xspr_promise_t* promise);

void xspr_result_decref(pTHX_ xspr_result_t* result);

xspr_result_t* xspr_invoke_perl(pTHX_ SV* perl_fn, SV** inputs, unsigned input_count);


typedef struct {
    HV* pxs_stash;
    HV* pxs_deferred_stash;
} my_cxt_t;

typedef struct {
    xspr_promise_t* promise;
} DEFERRED_CLASS_TYPE;

START_MY_CXT

/* Frees the xspr_callback_t structure */
void xspr_callback_free(pTHX_ xspr_callback_t *callback)
{
    if (callback->type == XSPR_CALLBACK_CHAIN) {
        xspr_promise_decref(aTHX_ callback->chain);

    } else if (callback->type == XSPR_CALLBACK_PERL) {
        SvREFCNT_dec(callback->perl.on_resolve);
        SvREFCNT_dec(callback->perl.on_reject);
        if (callback->perl.next != NULL)
            xspr_promise_decref(aTHX_ callback->perl.next);

    } else if (callback->type == XSPR_CALLBACK_FINALLY) {
        SvREFCNT_dec(callback->finally.on_finally);
        if (callback->finally.next != NULL)
            xspr_promise_decref(aTHX_ callback->finally.next);

    } else {
        assert(0);
    }

    Safefree(callback);
}

/* Decrements the ref count for the xspr_result_t, freeing the structure if needed */
void xspr_result_decref(pTHX_ xspr_result_t* result)
{
    if (--(result->refs) == 0) {
        unsigned i;
        for (i = 0; i < result->count; i++) {
            SvREFCNT_dec(result->results[i]);
        }
        Safefree(result->results);
        Safefree(result);
    }
}

/* Decrements the ref count for the xspr_promise_t, freeing the structure if needed */
void xspr_promise_decref(pTHX_ xspr_promise_t *promise)
{
    if (--(promise->refs) == 0) {
        if (promise->state == XSPR_STATE_PENDING) {
            /* XXX: is this a bad thing we should warn for? */
            int count = promise->pending.callbacks_count;
            xspr_callback_t **callbacks = promise->pending.callbacks;
            int i;
            for (i = 0; i < count; i++) {
                xspr_callback_free(aTHX_ callbacks[i]);
            }
            Safefree(callbacks);

        } else {
            assert(0);
        }

        Safefree(promise);
    }
}

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

    SV *detect_leak_perl = get_sv("Demo::XS::DETECT_MEMORY_LEAKS", 0);

    promise->detect_leak_pid = SvTRUE(detect_leak_perl) ? getpid() : 0;

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

        xspr_promise_decref(aTHX_ self->promise);
        Safefree(self);
