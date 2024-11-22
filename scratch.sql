-- -*- sql-product: postgres; -*-

-- The pgrag extension is *experimental*.

SET neon.allow_unstable_extensions='true'

-- The primary extension

create extension if not exists rag cascade;

-- Model extension for local tokenizing and embedding generation

create extension if not exists rag_bge_small_en_v15 cascade;

-- Model extension for reranking

create extension if not exists rag_jina_reranker_v1_tiny_en cascade;

-- Securely retrieve API key and store in psql variable.

\set anthropic_key `gpg -q --for-your-eyes-only --no-tty -d ~/.authinfo.gpg | awk '/machine anthropic.ai login apikey/ {print $NF}'`

-- Set the API key using psql variable.

select rag.anthropic_set_api_key(:'anthropic_key');

-- Test an Anthropic chat message with a custom system prompt.

select
  *
  from
    jsonb_path_query(
      rag.anthropic_messages(
	'2023-06-01',
	format(
$$
{
  "model": "claude-3-haiku-20240307",
  "max_tokens": 1024,
  "system": "Please answer like a 17th century pirate.",
  "messages": [
    {
      "role": "user",
      "content": "%s"
    }
  ]
}
$$, 'How far is the Earth from the Sun?')::json)::jsonb, '$.content[*].text');

-- Create a view over large objects which are PDFs, omitting the content.

create or replace view pdf as
  select
    oid,
    obj_description(oid, 'pg_largeobject')::json->>'name' as name
    from
      pg_largeobject_metadata
   where true
     and obj_description(oid, 'pg_largeobject') is json
     and obj_description(oid, 'pg_largeobject')::json->>'content-type' ilike 'application/pdf';

-- Create a companion view over large objects which are PDFs, with the content.

create or replace view pdf_content as
  select
    oid,
    rag.text_from_pdf(lo_get(oid)) as fulltext
    from
      pg_largeobject_metadata
      natural join pdf;

-- Create a table to contain chunks and their embeddings.

create table if not exists embedding (
  id int primary key generated always as identity,
  doc_oid oid not null,
  chunk text not null,
  embedding vector(384));

-- Add a vector index to the embedding column.

create index on embedding using hnsw (embedding vector_cosine_ops);

-- Reset large objects.

select lo_unlink(oid) from pg_largeobject_metadata;

-- Add PDF documents in the current directory as large objects with encoded metadata.

\! find . -type f -name "*.pdf" -exec echo \\lo_import \'{}\' \'\{\"name\": \"{}\", \"content-type\": \"application/pdf\"\}\' \; | psql $(neonctl connection-string)

-- Store chunks of the PDF document content and corresponding embeddings.

with
  chunks as (
    select
      oid,
      unnest(rag_bge_small_en_v15.chunks_by_token_count(fulltext, 192, 8)) as chunk
      from
	pdf_content)
insert into embedding(doc_oid, chunk, embedding) (
  select
    oid,
    chunk,
    rag_bge_small_en_v15.embedding_for_passage(chunk)
    from
      chunks);

-- Store a question about the indexed documents into a psql variable.

\set query 'Are foreign key constraints disabled in PostgreSQL Logical Replication subscriptions?'

\set query 'How do you change an unlogged table to a PostgreSQL logged table?'

\set query 'What is the circumference of the Earth in nautical miles?'

-- Message Anthropic with the question and with optimal context.

with
  ranked as (			--Perform a semantic search of query over chunks.
    select
      id,
      doc_oid,
      chunk
      from embedding
     order by rag_bge_small_en_v15.embedding_for_query(:'query')
     limit 100),
  reranked as (			--Skim an optimal ordering of the retrieved chunks.
    select
      *
      from
	ranked
     order by rag_jina_reranker_v1_tiny_en.rerank_distance(:'query', chunk)
     limit 50),
  message as (			--Create a package of messages with the queries (1) and a system prompt with the skimmed chunks.
    select
      json_object(
	'model': 'claude-3-haiku-20240307',
	'max_tokens': 256,
	'system': format($$The user is a PostgreSQL user or developer.  Please try to answer the question using the following CONTEXT.  If the context is not relevant or complete enough to answer the question confidently, then only say "I cannot answer that question.".  CONTEXT:  %s$$, string_agg(chunk, E'\n\n')),
	'messages': json_array(
	  json_object(
	    'role': 'user',
	    'content': :'query')))
      from
	reranked),
  response as (			--Send the package of messages to Anthropic.
    select
      replace(jsonb_path_query(rag.anthropic_messages('2023-06-01', json_object)::jsonb, '$.content[*].text')::text, '\n', chr(10))
      from
	message)
select * from response;		--Show the results.
