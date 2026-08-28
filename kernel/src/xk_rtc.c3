module xk;
// ============================================================================
// xenOS CMOS real-time clock driver. Reads the current wall-clock time via
// the RTC at ports 0x70/0x71 (works on real hardware like the ThinkPad X390
// Yoga's PCH RTC, and on QEMU which emulates the MC146818 RTC).
// Handles BCD/binary (register B bit 2) and 12/24-hour (register B bit 1).
// ============================================================================

const uint RTC_IDX = 0x70;
const uint RTC_DAT = 0x71;
// xk_outb / xk_inb are declared in xk_core.c3 (same module).

fn char rtc_read(uint reg)
{
    xk_outb(RTC_IDX, (char)(reg & 0x7F));
    return xk_inb(RTC_DAT);
}

fn void rtc_wait_ready()
{
    while ((rtc_read(0x0A) & 0x80) != 0) { }   // update-in-progress bit clear means stable
}

fn char bcd2bin(char b)
{
    return (char)(((char)(b >> 4) & 0x0F) * 10 + (b & 0x0F));
}

// Read time into hour/min/sec (24-hour, binary). Returns true on success.
fn bool rtc_read_time(int* hour, int* min, int* sec)
{
    rtc_wait_ready();
    char regB = rtc_read(0x0B);
    bool binary = (regB & 0x04) != 0;
    bool ampm  = (regB & 0x02) != 0;
    char se = rtc_read(0x00);
    char mi = rtc_read(0x02);
    char hr = rtc_read(0x04);
    // values may be read mid-update; re-read stable snapshot
    rtc_wait_ready();
    se = rtc_read(0x00);
    mi = rtc_read(0x02);
    hr = rtc_read(0x04);
    if (!binary)
    {
        se = bcd2bin(se);
        mi = bcd2bin(mi);
        if (ampm)
        {
            bool pm = (hr & 0x80) != 0;
            hr = bcd2bin(hr & 0x7F);
            if (pm) { hr += 12; }
            if (hr == 12 || hr == 24) { hr = (char)(hr - 12); }   // 12am/12pm map
            if (pm && hr == 0) { hr = 12; }
        }
        else
        {
            hr = bcd2bin(hr & 0x7F);
        }
    }
    *hour = (int)hr;
    *min  = (int)mi;
    *sec  = (int)se;
    return true;
}