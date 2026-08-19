-- ============================================================
-- Campus Portal — Supabase schema
-- วิธีใช้: เปิด Supabase Dashboard -> SQL Editor -> วางไฟล์นี้ทั้งหมด -> Run
-- ============================================================

create extension if not exists "uuid-ossp";

-- ---------- ตารางโปรไฟล์ผู้ใช้ (นักศึกษา/อาจารย์) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  student_id text unique not null,          -- รหัสนักศึกษา/รหัสอาจารย์ (ใช้ล็อกอิน)
  name text not null,
  room text not null default '-',
  gender text not null check (gender in ('male', 'female', 'other')),
  role text not null check (role in ('student', 'teacher')),
  created_at timestamptz not null default now()
);

-- ---------- Migration: เพิ่มคอลัมน์ gender ถ้าตาราง profiles มีอยู่ก่อนแล้ว ----------
-- (บล็อกนี้ปลอดภัยสำหรับทั้งฐานข้อมูลใหม่และฐานข้อมูลเดิมที่เคยรัน schema.sql เวอร์ชันก่อนหน้าแล้ว)
alter table public.profiles add column if not exists gender text;
update public.profiles set gender = 'other' where gender is null;
alter table public.profiles alter column gender set not null;
do $$
begin
  if not exists (
    select 1 from information_schema.table_constraints
    where constraint_name = 'profiles_gender_check' and table_name = 'profiles'
  ) then
    alter table public.profiles add constraint profiles_gender_check check (gender in ('male', 'female', 'other'));
  end if;
end $$;

-- ---------- Migration: เพิ่มคอลัมน์ avatar_url สำหรับรูปนักศึกษา ----------
alter table public.profiles add column if not exists avatar_url text;

-- ---------- Storage bucket สำหรับเก็บรูปนักศึกษา/อาจารย์ ----------
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- ---------- Policy: storage.objects ----------
-- ทุกคนอ่านรูปได้ (เพราะเป็นรูปโปรไฟล์ที่แสดงในบัตร/แดชบอร์ด)
drop policy if exists "avatars_public_read" on storage.objects;
create policy "avatars_public_read"
  on storage.objects for select
  using (bucket_id = 'avatars');

-- ผู้ใช้อัปโหลดรูปได้เฉพาะในโฟลเดอร์ของตัวเอง (path: {user_id}/filename.ext)
drop policy if exists "avatars_insert_own" on storage.objects;
create policy "avatars_insert_own"
  on storage.objects for insert
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own"
  on storage.objects for update
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own"
  on storage.objects for delete
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- ตารางคะแนน ----------
-- หมายเหตุ: score คือ "คะแนนดิบ" ของแต่ละวิชา (เต็ม 20 ต่อวิชา ตามข้อสอบแต่ละชุด)
-- หน้าแดชบอร์ดจะนำคะแนนของ 3 วิชามาบวกกันตรงๆ เป็นคะแนนรวมเต็ม 60 (ไม่หารเฉลี่ย)
create table if not exists public.scores (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid not null references public.profiles (id) on delete cascade,
  subject text not null,
  score numeric not null check (score >= 0 and score <= 100),
  updated_at timestamptz not null default now(),
  unique (student_id, subject)
);

-- ---------- เปิดใช้งาน Row Level Security ----------
alter table public.profiles enable row level security;
alter table public.scores enable row level security;

-- ---------- ฟังก์ชันช่วยตรวจสอบว่าเป็นอาจารย์หรือไม่ ----------
create or replace function public.is_teacher()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'teacher'
  );
$$;

-- ---------- Policy: profiles ----------
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "profiles_select_teacher_all" on public.profiles;
create policy "profiles_select_teacher_all"
  on public.profiles for select
  using (public.is_teacher());

drop policy if exists "profiles_insert_self" on public.profiles;
create policy "profiles_insert_self"
  on public.profiles for insert
  with check (auth.uid() = id);

-- ---------- Policy: scores ----------
drop policy if exists "scores_select_own" on public.scores;
create policy "scores_select_own"
  on public.scores for select
  using (auth.uid() = student_id);

drop policy if exists "scores_select_teacher_all" on public.scores;
create policy "scores_select_teacher_all"
  on public.scores for select
  using (public.is_teacher());

drop policy if exists "scores_insert_teacher" on public.scores;
create policy "scores_insert_teacher"
  on public.scores for insert
  with check (public.is_teacher());

drop policy if exists "scores_update_teacher" on public.scores;
create policy "scores_update_teacher"
  on public.scores for update
  using (public.is_teacher());

-- ---------- ตารางบันทึกการทำข้อสอบ (Quiz Attempts) ----------
-- ทุกครั้งที่นักศึกษาส่งคำตอบในหน้าข้อสอบ (quiz_1_hydraulic.html ฯลฯ) จะมีการ insert แถวใหม่ที่นี่
-- โดยหน้าเว็บ (quiz-common.js) เป็นตัวคำนวณ "ทำครั้งที่" (attempt_no) และเวลาเริ่ม/เสร็จให้อัตโนมัติ
create table if not exists public.quiz_attempts (
  id uuid primary key default uuid_generate_v4(),
  student_id uuid not null references public.profiles (id) on delete cascade,
  subject text not null,           -- ต้องตรงกับชื่อวิชาใน SUBJECTS ของ index.html และ QUIZ_SUBJECT ของหน้าข้อสอบ
  attempt_no integer not null,     -- ทำครั้งที่เท่าไหร่ของวิชานี้ (นับจากฝั่งเว็บ)
  score numeric not null,          -- คะแนนดิบที่ทำได้ เช่น 17
  total integer not null,          -- คะแนนเต็ม เช่น 20
  started_at timestamptz not null, -- เวลาที่เริ่มทำข้อสอบ
  finished_at timestamptz not null,-- เวลาที่ส่งคำตอบ
  created_at timestamptz not null default now()
);

alter table public.quiz_attempts enable row level security;

-- นักศึกษาเห็นเฉพาะประวัติการทำข้อสอบของตัวเอง
drop policy if exists "quiz_attempts_select_own" on public.quiz_attempts;
create policy "quiz_attempts_select_own"
  on public.quiz_attempts for select
  using (auth.uid() = student_id);

-- อาจารย์เห็นประวัติการทำข้อสอบของนักศึกษาทุกคน
drop policy if exists "quiz_attempts_select_teacher_all" on public.quiz_attempts;
create policy "quiz_attempts_select_teacher_all"
  on public.quiz_attempts for select
  using (public.is_teacher());

-- นักศึกษาบันทึกผลของตัวเองได้เท่านั้น (จากหน้าข้อสอบหลังทำเสร็จ)
drop policy if exists "quiz_attempts_insert_own" on public.quiz_attempts;
create policy "quiz_attempts_insert_own"
  on public.quiz_attempts for insert
  with check (auth.uid() = student_id);

-- ---------- (ไม่บังคับ) ตัวอย่างข้อมูลวิชาเริ่มต้นให้อาจารย์เพิ่มคะแนนเอง ----------
-- คุณสามารถเพิ่มคะแนนได้ภายหลังจากหน้าเว็บ (บทบาทอาจารย์) หรือรันคำสั่ง insert เองที่นี่
-- หมายเหตุ: ตาราง scores จะถูกอัปเดตอัตโนมัติทุกครั้งที่นักศึกษาทำข้อสอบเสร็จ (ผ่าน quiz-common.js)
-- อาจารย์ยังสามารถแก้ไขคะแนนในตาราง scores ได้เองจากหน้าแดชบอร์ดเช่นเดิม