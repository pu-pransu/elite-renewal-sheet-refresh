with base as (
    select
        subs.userid,
        subs.id as subscription_id,
        case when planid like 'advisory-elite-1m%'  then '1Month'
             when planid =    'advisory-elite-family' then 'Family'
             else 'Yearly' end                       as planid,
        subs.status,
        to_timestamp_ltz(starttime) as start_ts,
        to_timestamp_ltz(expiresat) as expiry_ts,
        subs.created_at,
        iff(subs.status in ('ACTIVE','EXPIRED','AWAITING_ACTIVATION'),1,0) as in_chain,
        round(case when date(starttime)>'2025-09-01' and date(starttime)<'2025-11-09'
        then '1178.82' else  subs.paymententities[0]:amount::STRING end/1.18,2) as amount_excl_gst,
        case when date(starttime)>'2025-09-01' and date(starttime)<'2025-11-09'
        then '1178.82' else  paymententities[0]:amount::STRING end as amount_incl_gst,
        date(case when subs.status='CANCELLED' then updated_at end) as cancellation_date,
        paymententities[0]:paymentId::STRING as paymentId,
        cb.ID as razorpay_order_id
    from reports_db.reports.subscription_platform_subscriptions as subs
    left join reports_db.reports.repayment_repayment_txn as txn
        on txn.repaymentid = paymententities[0]:paymentId::STRING
    left join (
        select * from reports_db.reports.repayment_callback
        qualify row_number() over (partition by repaymentid order by updatedat asc) = 1
    ) as cb on cb.repaymentid = txn.repaymentid
    where planid like '%advisory-elite%'
    and planid not like '%advisory-elite-1m%'
      and subs.status in ('ACTIVE','EXPIRED','AWAITING_ACTIVATION','CANCELLED')
      and subs.starttime is not null
),

seq as (
    select
        b.*,
        case when in_chain = 1 then row_number() over (partition by userid, in_chain order by start_ts) end as sub_num,
        case when in_chain = 1 then lag(subscription_id) over (partition by userid, in_chain order by start_ts) end as prev_sub_id,
        case when in_chain = 1 then lag(expiry_ts)       over (partition by userid, in_chain order by start_ts) end as prev_expiry_ts,
        case when in_chain = 1 then lag(status)          over (partition by userid, in_chain order by start_ts) end as prev_status,
        case when in_chain = 1 then lag(planid)          over (partition by userid, in_chain order by start_ts) end as prev_planid,
        case when in_chain = 1 then lead(subscription_id) over (partition by userid, in_chain order by start_ts) end as next_sub_id,
        case when in_chain = 1 then lead(created_at)      over (partition by userid, in_chain order by start_ts) end as next_created_at,
        case when in_chain = 1 then lead(start_ts)        over (partition by userid, in_chain order by start_ts) end as next_start_ts
    from base b
),

tagged as (
    select
        seq.*,
        case when in_chain = 0        then null
             when prev_sub_id is null then 'FIRST_PURCHASE'
             else                          'RENEWAL'
        end                                          as purchase_type,
        iff(next_sub_id is not null, 1, 0)           as was_renewed,
        date(expiry_ts)                              as expiry_date,
        date(date_trunc(week,  expiry_ts))           as expiry_week,
        date(date_trunc(month, expiry_ts))           as expiry_month,
        date(next_created_at)                        as renewed_date,
        date(date_trunc(month, next_created_at))     as renewal_month
    from seq
),

-- ===== engagement =====
uw_map as (                       -- UniWealth ID (subs) -> Uni ID (events)
    select distinct user_id as uw_user_id, external_user_id as uni_user_id
    from reports_db.reports.user_orchestrator_user
    where right(external_user_id, 9) not in ('-inactive', '-deactive')
),

sessions_monthly as (             -- distinct sessions per user per month
    select
        ud.userid,
        date_trunc(month, timestamp) as dt,
        count(distinct coalesce(session_id1, session_id2, session_id3)) as sessions
    from reports_db.events.moengage_events as moe
    left join reports_db.reports.user_profile_user_details as ud on ud.hash_value = moe.uid
    where coalesce(session_id1, session_id2, session_id3) is not null
      and event_time > '2025-12-31 23:59:59'
      and event_time < current_date()
    group by all
),

engagement as (                   
    select
        e.userid,
        e.expiry_month,
        sum(coalesce(s.sessions, 0)) / 3 as avg_sessions_month
    from (select distinct userid, expiry_month from tagged where in_chain = 1) e
    left join uw_map m           on m.uw_user_id = e.userid
    left join sessions_monthly s on s.userid = m.uni_user_id
                                and datediff(month, s.dt, e.expiry_month) between 2 and 4
    group by 1, 2
),
-- ======================

ffinal as (
    select
        t.expiry_date,
        t.expiry_week,
        t.expiry_month,
        t.renewed_date,
        date(date_trunc(week, t.renewed_date))   as renewed_week,
        t.renewal_month,
        case
            when up.portfolio_value is null      then 'F. Unknown'
            when up.portfolio_value <  500000    then 'A. <5L'
            when up.portfolio_value <  1000000   then 'B. 5-10L'
            when up.portfolio_value <  2500000   then 'C. 10-25L'
            when up.portfolio_value <  5000000   then 'D. 25-50L'
            else                                      'E. 50L+'
        end                                      as portfolio_value,
        case
            when en.avg_sessions_month <  1  then 'A.<1 Bucket'
            when en.avg_sessions_month <= 6  then 'B.2-6'
            when en.avg_sessions_month <= 11 then 'C.7-11'
            else                                  'F.12+'
        end                                      as avg_sessions_month_bucket,
        count(distinct t.userid)                 as usrs
    from tagged t
    left join reports_db.reports.user_fact_data_uw up on up.uw_user_id = t.userid
    left join engagement en on en.userid = t.userid and en.expiry_month = t.expiry_month
    where t.in_chain = 1
    group by 1, 2, 3, 4, 5, 6, 7, 8
)

select
    *,
    case when renewed_date is null then 1 else 2 end as subscription_purchase_count
from ffinal
order by 1, 4, 7, 8