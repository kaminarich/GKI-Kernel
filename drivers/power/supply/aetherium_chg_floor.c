// SPDX-License-Identifier: GPL-2.0
/*
 * Aetherium charge throttle floor
 *
 * On MediaTek android12-5.10 the charging current ceiling is carried by two
 * writable power supply properties on the vendor charger ("mtk-master-charger"
 * and friends): POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT and
 * POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX. The vendor charging algorithm
 * treats them as a min() ceiling, where -1 means "no limit".
 *
 * Both throttle routes - the thermal governor updating the vendor charger
 * cooling device, and the thermal HAL writing cooling_deviceN/cur_state -
 * end up in that cooling device, which applies the throttle by calling
 * power_supply_set_property() on the charger. That call is the only part of
 * the path that lives in the GKI image, so it is the single place where the
 * depth of charge throttling can be bounded.
 *
 * This bounds how far a throttle may cut the charging current, without ever
 * raising it above what the vendor asks for when it is not throttling:
 *
 *   - a request of -1 (no limit) is never modified
 *   - a request of 0 (stop charging: battery full, JEITA cutoff, fault,
 *     emergency cooling state) is never modified
 *   - a positive request below the configured floor is raised to the floor,
 *     but only while the battery temperature is below temp_limit_dc
 *
 * The defaults sit below the stock android12-5.10 MediaTek limits
 * (AC_CHARGER_CURRENT 2050000, AC_CHARGER_INPUT_CURRENT 3200000), so the
 * charger is never driven past its normal unthrottled operating point; only
 * the depth of thermal throttling changes.
 *
 * Runtime control lives in /sys/kernel/aetherium_charging/.
 */

#include <linux/atomic.h>
#include <linux/init.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/kobject.h>
#include <linux/power_supply.h>
#include <linux/printk.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#include "power_supply.h"

/* Battery temperature is reported in tenths of a degree Celsius. */
#define AETH_TEMP_UNKNOWN		INT_MIN
#define AETH_TEMP_POLL_MS		5000
#define AETH_IDLE_TIMEOUT_MS		30000

static bool aeth_enabled = true;
static unsigned int aeth_input_floor_ua = 2000000;	/* 2.00 A */
static unsigned int aeth_charge_floor_ua = 1800000;	/* 1.80 A */
static int aeth_temp_limit_dc = 440;			/* 44.0 degC */
static bool aeth_verbose;

static atomic_t aeth_batt_temp_dc = ATOMIC_INIT(AETH_TEMP_UNKNOWN);
static atomic_t aeth_raise_count = ATOMIC_INIT(0);
static unsigned long aeth_last_request;

static void aeth_temp_work_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(aeth_temp_work, aeth_temp_work_fn);

/*
 * Sample the battery temperature outside of the set_property() path, which may
 * run in atomic context. While no charger limit has been seen for
 * AETH_IDLE_TIMEOUT_MS the sampling stops and the cached value is invalidated,
 * so nothing polls while the device is not charging.
 */
static void aeth_temp_work_fn(struct work_struct *work)
{
	union power_supply_propval val;
	struct power_supply *batt;

	batt = power_supply_get_by_name("battery");
	if (batt) {
		if (!power_supply_get_property(batt, POWER_SUPPLY_PROP_TEMP, &val))
			atomic_set(&aeth_batt_temp_dc, val.intval);
		power_supply_put(batt);
	}

	if (time_before(jiffies,
			READ_ONCE(aeth_last_request) +
			msecs_to_jiffies(AETH_IDLE_TIMEOUT_MS)))
		schedule_delayed_work(&aeth_temp_work,
				      msecs_to_jiffies(AETH_TEMP_POLL_MS));
	else
		atomic_set(&aeth_batt_temp_dc, AETH_TEMP_UNKNOWN);
}

/**
 * aeth_chg_floor_filter - bound the depth of a charger current throttle
 * @psy_name: name of the power supply being written
 * @psp: property being written
 * @ua: value requested by the caller, in microamps
 *
 * Returns the value to hand to the vendor driver. Only positive limits below
 * the configured floor on a charger power supply are changed.
 */
int aeth_chg_floor_filter(const char *psy_name, enum power_supply_property psp,
			  int ua)
{
	unsigned int floor;
	int temp;

	if (!READ_ONCE(aeth_enabled))
		return ua;

	/* -1 is "no limit", 0 is "stop charging". Never touch either. */
	if (ua <= 0)
		return ua;

	if (!psy_name || !strstr(psy_name, "charger"))
		return ua;

	switch (psp) {
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		floor = READ_ONCE(aeth_input_floor_ua);
		break;
	case POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT_MAX:
		floor = READ_ONCE(aeth_charge_floor_ua);
		break;
	default:
		return ua;
	}

	WRITE_ONCE(aeth_last_request, jiffies);
	if (!delayed_work_pending(&aeth_temp_work))
		schedule_delayed_work(&aeth_temp_work, 0);

	if (!floor || ua >= (int)floor)
		return ua;

	temp = atomic_read(&aeth_batt_temp_dc);
	if (temp != AETH_TEMP_UNKNOWN && temp >= READ_ONCE(aeth_temp_limit_dc)) {
		if (READ_ONCE(aeth_verbose))
			pr_info("aetherium_chg: battery %d.%d degC, honouring %d uA on %s\n",
				temp / 10, abs(temp % 10), ua, psy_name);
		return ua;
	}

	atomic_inc(&aeth_raise_count);
	if (READ_ONCE(aeth_verbose))
		pr_info("aetherium_chg: %s %s %d -> %u uA\n", psy_name,
			psp == POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT ?
				"input limit" : "charge limit",
			ua, floor);

	return (int)floor;
}

#define AETH_ATTR_RW(_name, _var, _fmt, _parse, _min, _max)		\
static ssize_t _name##_show(struct kobject *kobj,			\
			    struct kobj_attribute *attr, char *buf)	\
{									\
	return sysfs_emit(buf, _fmt "\n", READ_ONCE(_var));		\
}									\
static ssize_t _name##_store(struct kobject *kobj,			\
			     struct kobj_attribute *attr,		\
			     const char *buf, size_t count)		\
{									\
	typeof(_var) val;						\
									\
	if (_parse(buf, 0, &val))					\
		return -EINVAL;						\
	if ((long long)val < (long long)(_min) ||			\
	    (long long)val > (long long)(_max))				\
		return -ERANGE;						\
	WRITE_ONCE(_var, val);						\
	return count;							\
}									\
static struct kobj_attribute aeth_attr_##_name =			\
	__ATTR(_name, 0644, _name##_show, _name##_store)

static ssize_t enabled_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(aeth_enabled));
}

static ssize_t enabled_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	bool val;

	if (kstrtobool(buf, &val))
		return -EINVAL;

	WRITE_ONCE(aeth_enabled, val);
	return count;
}
static struct kobj_attribute aeth_attr_enabled =
	__ATTR(enabled, 0644, enabled_show, enabled_store);

static ssize_t verbose_show(struct kobject *kobj, struct kobj_attribute *attr,
			    char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(aeth_verbose));
}

static ssize_t verbose_store(struct kobject *kobj, struct kobj_attribute *attr,
			     const char *buf, size_t count)
{
	bool val;

	if (kstrtobool(buf, &val))
		return -EINVAL;

	WRITE_ONCE(aeth_verbose, val);
	return count;
}
static struct kobj_attribute aeth_attr_verbose =
	__ATTR(verbose, 0644, verbose_show, verbose_store);

/* Floors are capped at the stock MediaTek AC limits, see mtk_charger.h. */
AETH_ATTR_RW(input_floor_ua, aeth_input_floor_ua, "%u", kstrtouint, 0, 3200000);
AETH_ATTR_RW(charge_floor_ua, aeth_charge_floor_ua, "%u", kstrtouint, 0, 2050000);
AETH_ATTR_RW(temp_limit_dc, aeth_temp_limit_dc, "%d", kstrtoint, 0, 600);

static ssize_t battery_temp_dc_show(struct kobject *kobj,
				    struct kobj_attribute *attr, char *buf)
{
	int temp = atomic_read(&aeth_batt_temp_dc);

	if (temp == AETH_TEMP_UNKNOWN)
		return sysfs_emit(buf, "unknown\n");

	return sysfs_emit(buf, "%d\n", temp);
}
static struct kobj_attribute aeth_attr_battery_temp_dc =
	__ATTR(battery_temp_dc, 0444, battery_temp_dc_show, NULL);

static ssize_t raise_count_show(struct kobject *kobj,
				struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", atomic_read(&aeth_raise_count));
}
static struct kobj_attribute aeth_attr_raise_count =
	__ATTR(raise_count, 0444, raise_count_show, NULL);

static struct attribute *aeth_attrs[] = {
	&aeth_attr_enabled.attr,
	&aeth_attr_input_floor_ua.attr,
	&aeth_attr_charge_floor_ua.attr,
	&aeth_attr_temp_limit_dc.attr,
	&aeth_attr_verbose.attr,
	&aeth_attr_battery_temp_dc.attr,
	&aeth_attr_raise_count.attr,
	NULL,
};
ATTRIBUTE_GROUPS(aeth);

static struct kobject *aeth_kobj;

void __init aeth_chg_floor_init(void)
{
	int ret;

	aeth_kobj = kobject_create_and_add("aetherium_charging", kernel_kobj);
	if (!aeth_kobj) {
		pr_warn("aetherium_chg: cannot create sysfs directory\n");
		return;
	}

	ret = sysfs_create_groups(aeth_kobj, aeth_groups);
	if (ret) {
		pr_warn("aetherium_chg: cannot create sysfs nodes: %d\n", ret);
		kobject_put(aeth_kobj);
		aeth_kobj = NULL;
		return;
	}

	pr_info("aetherium_chg: throttle floor %u uA input, %u uA charge, up to %d.%d degC\n",
		aeth_input_floor_ua, aeth_charge_floor_ua,
		aeth_temp_limit_dc / 10, aeth_temp_limit_dc % 10);
}
