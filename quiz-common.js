// ============================================================
// quiz-common.js — สคริปต์ใช้ร่วมกันสำหรับหน้าข้อสอบทุกชุด (ATA Chapter Trainer)
//
// วิธีใช้ในหน้าข้อสอบแต่ละไฟล์ ให้ใส่ตามลำดับนี้ก่อน </body>:
//   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
//   <script src="../../config.js"></script>
//   <script>const QUIZ_SUBJECT = "ชื่อวิชาที่ต้องตรงกับ SUBJECTS ใน index.html";</script>
//   <script src="../../quiz-common.js"></script>
//
// จากนั้นในฟังก์ชัน submitQuiz() ของหน้าข้อสอบ ให้เรียก:
//   const meta = await window.saveQuizAttempt(score, QUESTIONS.length);
// แล้วนำ meta.startedAtText / meta.finishedAtText / meta.attemptNo ไปแสดงผล
// ============================================================
(function () {
  if (typeof QUIZ_SUBJECT === "undefined") {
    console.error("quiz-common.js: กรุณาประกาศ QUIZ_SUBJECT ก่อน include ไฟล์นี้");
    return;
  }

  const startedAt = new Date();
  let sb = null;
  let currentProfile = null;
  let attemptNo = 1;

  function pad(n) { return String(n).padStart(2, "0"); }

  // รูปแบบ: 12.00 18/08/2569 (ปี พ.ศ.)
  function formatThaiDT(d) {
    return `${pad(d.getHours())}.${pad(d.getMinutes())} ${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear() + 543}`;
  }

  async function initQuizAuth() {
    const banner = document.getElementById("quiz-user-banner");

    if (!window.supabase || typeof SUPABASE_URL === "undefined" || SUPABASE_URL.includes("YOUR-PROJECT-REF")) {
      console.warn("quiz-common: ไม่พบการตั้งค่า Supabase ที่ถูกต้อง — จะไม่มีการบันทึกคะแนน");
      return;
    }

    sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

    const { data: { session } } = await sb.auth.getSession();
    if (!session) {
      // ยังไม่ได้ล็อกอิน ส่งกลับไปหน้าเข้าสู่ระบบ
      window.location.href = "../../index.html";
      return;
    }

    const { data: profile } = await sb.from("profiles").select("*").eq("id", session.user.id).single();
    if (!profile) {
      window.location.href = "../../index.html";
      return;
    }
    currentProfile = profile;

    if (currentProfile.role === "student") {
      const { count } = await sb
        .from("quiz_attempts")
        .select("id", { count: "exact", head: true })
        .eq("student_id", currentProfile.id)
        .eq("subject", QUIZ_SUBJECT);
      attemptNo = (count || 0) + 1;
    }

    if (banner) {
      banner.style.display = "flex";
      banner.innerHTML = currentProfile.role === "teacher"
        ? `👤 เข้าสู่ระบบในนาม <strong>${currentProfile.name}</strong> (อาจารย์ — โหมดดูตัวอย่าง ไม่มีการบันทึกคะแนน)`
        : `👤 <strong>${currentProfile.name}</strong> · รหัส ${currentProfile.student_id} · นี่คือการทำครั้งที่ <strong>${attemptNo}</strong>`;
    }
  }

  window.quizAuthReady = initQuizAuth();

  // เรียกตอนส่งคำตอบ: บันทึกผลลง Supabase และคืนค่าข้อมูลเวลา/ครั้งที่ทำ สำหรับแสดงผล
  window.saveQuizAttempt = async function (score, total) {
    await window.quizAuthReady;
    const finishedAt = new Date();
    const meta = {
      attemptNo,
      startedAtText: formatThaiDT(startedAt),
      finishedAtText: formatThaiDT(finishedAt),
      saved: false,
    };

    if (!sb || !currentProfile || currentProfile.role !== "student") {
      return meta; // ไม่ได้ล็อกอินเป็นนักศึกษา จะไม่บันทึกลงฐานข้อมูล
    }

    const { error: attemptError } = await sb.from("quiz_attempts").insert({
      student_id: currentProfile.id,
      subject: QUIZ_SUBJECT,
      attempt_no: attemptNo,
      score,
      total,
      started_at: startedAt.toISOString(),
      finished_at: finishedAt.toISOString(),
    });

    if (!attemptError) {
      // เก็บคะแนนดิบ (เช่น 17 จาก 20) ลงตาราง scores โดยตรง — ไม่แปลงเป็นเปอร์เซ็นต์
      // เพื่อให้หน้าแดชบอร์ดนำ 3 วิชามาบวกกันตรงๆ ได้เป็นคะแนนเต็ม 60 (20+20+20)
      await sb.from("scores").upsert(
        { student_id: currentProfile.id, subject: QUIZ_SUBJECT, score: score },
        { onConflict: "student_id,subject" }
      );
      meta.saved = true;
    }

    return meta;
  };
})();