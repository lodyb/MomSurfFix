// Surf Stuck Fix
//
// Replaces CGameMovement::TryPlayerMove with Momentum Mod's version, which
// recovers from the ramp collision bugs vanilla movement can't: instead of
// zeroing velocity when a move trace starts inside a surface, it hunts for
// the plane the player is actually pressed against and clips velocity along
// it, so surfers slide on instead of stopping dead.
//
// On top of the Momentum port, this fork adds an embedded-hull rescue: when
// the hull is *fully* inside solid (headsurf wedges, enclosed pockets that
// pin feet and head at once) no plane is findable in any direction, so the
// plugin searches the nearby space for the closest spot the hull fits and
// resumes the move from there with velocity intact.
//
// File/gamedata/cvar names keep the momsurffix2 prefix for compatibility
// with existing server configs.

#include "sourcemod"
#include "sdktools"
#include "sdkhooks"
#include "dhooks"

#define SNAME "[momsurffix2] "
#define GAME_DATA_FILE "momsurffix2.games"
// #define DEBUG_MEMTEST

public Plugin myinfo = {
    name = "Surf Stuck Fix",
    author = "GAMMA CASE, lodyb",
    description = "Fixes ramp collision bugs and unsticks embedded players.",
    version = "1.3.0",
    url = "https://github.com/lodyb/MomSurfFix"
};

#define FLT_EPSILON 1.192092896e-07
#define MAX_CLIP_PLANES 5
// seam-pierce tier (ported from SurfSam's CS2-gist adaptation)
#define RAMP_PIERCE_DISTANCE 0.0625
#define RAMP_BUG_THRESHOLD 0.98
#define NEW_RAMP_THRESHOLD 0.95

enum OSType
{
	OSUnknown = -1,
	OSWindows = 1,
	OSLinux = 2
};

OSType gOSType;
EngineVersion gEngineVersion;

#define XYZ(%0) %0[0], %0[1], %0[2]

#define ASSERTUTILS_FAILSTATE_FUNC SetFailStateCustom
#define MEMUTILS_PLUGINENDCALL
#include "glib/memutils"
#undef MEMUTILS_PLUGINENDCALL

#include "momsurffix/utils.sp"
#include "momsurffix/baseplayer.sp"
#include "momsurffix/gametrace.sp"
#include "momsurffix/gamemovement.sp"

ConVar gRampBumpCount,
	gBounce,
	gRampInitialRetraceLength,
	gNoclipWorkAround,
	gRescue,
	gPierce,
	gSweepFast;

// last plane each player validly collided with; keyed by ehandle so a
// reconnect in the same slot resets it
float gLastPlane[MAXPLAYERS + 1][3];
int gLastPlaneHandle[MAXPLAYERS + 1];

float vec3_origin[3] = {0.0, 0.0, 0.0};
bool gBasePlayerLoadedTooEarly;


public void OnPluginStart()
{
#if defined DEBUG_MEMTEST
	RegAdminCmd("sm_mom_dumpmempool", SM_Dumpmempool, ADMFLAG_ROOT, "Dumps active momory pool. Mainly for debugging.");
#endif
	
	gRampBumpCount = CreateConVar("momsurffix_ramp_bumpcount", "8", "Helps with fixing surf/ramp bugs", .hasMin = true, .min = 4.0, .hasMax = true, .max = 16.0);
	gRampInitialRetraceLength = CreateConVar("momsurffix_ramp_initial_retrace_length", "0.2", "Amount of units used in offset for retraces", .hasMin = true, .min = 0.2, .hasMax = true, .max = 5.0);
	gNoclipWorkAround = CreateConVar("momsurffix_enable_noclip_workaround", "1", "Enables workaround to prevent issue #1, can actually help if momsuffix_enable_asm_optimizations is 0", .hasMin = true, .min = 0.0, .hasMax = true, .max = 1.0);
	gPierce = CreateConVar("momsurffix_pierce", "1", "Enable the seam-pierce tier: dodge phantom/deviant collision planes on ramp seams", .hasMin = true, .min = 0.0, .hasMax = true, .max = 1.0);
	gSweepFast = CreateConVar("momsurffix_sweep_fast", "1", "Replace the legacy 27-trace stuck sweep with a directional probe (0 = legacy momentum-mod sweep)", .hasMin = true, .min = 0.0, .hasMax = true, .max = 1.0);
	gRescue = CreateConVar("momsurffix_rescue", "1", "Enable the embedded-hull rescue; 0 reproduces stock 1.1.5 stuck behaviour", .hasMin = true, .min = 0.0, .hasMax = true, .max = 1.0);
	gBounce = FindConVar("sv_bounce");
	ASSERT_MSG(gBounce, "\"sv_bounce\" convar wasn't found!");
	
	AutoExecConfig();
	
	GameData gd = new GameData(GAME_DATA_FILE);
	ASSERT_FINAL(gd);
	
	ValidateGameAndOS(gd);
	
	InitUtils(gd);
	InitGameTrace(gd);
	gBasePlayerLoadedTooEarly = InitBasePlayer(gd);
	InitGameMovement(gd);
	
	SetupDhooks(gd);
	
	delete gd;
}

public void OnMapStart()
{
	if(gBasePlayerLoadedTooEarly)
	{
		GameData gd = new GameData(GAME_DATA_FILE);
		LateInitBasePlayer(gd);
		gBasePlayerLoadedTooEarly = false;
		delete gd;
	}
}

public void OnPluginEnd()
{
	CleanUpUtils();
}

#if defined DEBUG_MEMTEST
public Action SM_Dumpmempool(int client, int args)
{
	DumpMemoryUsage();
	
	return Plugin_Handled;
}
#endif


void ValidateGameAndOS(GameData gd)
{
	gOSType = view_as<OSType>(gd.GetOffset("OSType"));
	ASSERT_FINAL_MSG(gOSType != OSUnknown, "Failed to get OS type or you are trying to load it on unsupported OS!");
	
	gEngineVersion = GetEngineVersion();
	ASSERT_FINAL_MSG(gEngineVersion == Engine_CSS || gEngineVersion == Engine_CSGO, "Only CSGO and CSS are supported by this plugin!");
}

void SetupDhooks(GameData gd)
{
	Handle dhook = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Int, ThisPointer_Address);
	
	DHookSetFromConf(dhook, gd, SDKConf_Signature, "CGameMovement::TryPlayerMove");
	DHookAddParam(dhook, HookParamType_Int);
	DHookAddParam(dhook, HookParamType_Int);
	
	if(gEngineVersion == Engine_CSS)
		DHookAddParam(dhook, HookParamType_Float);
	
	ASSERT(DHookEnableDetour(dhook, false, TryPlayerMove_Dhook));
}

public MRESReturn TryPlayerMove_Dhook(Address pThis, Handle hReturn, Handle hParams)
{
	Address pFirstDest = DHookGetParam(hParams, 1);
	Address pFirstTrace = DHookGetParam(hParams, 2);
	
	DHookSetReturn(hReturn, TryPlayerMove(view_as<CGameMovement>(pThis), view_as<Vector>(pFirstDest), view_as<CGameTrace>(pFirstTrace)));
	
	return MRES_Supercede;
}

int TryPlayerMove(CGameMovement pThis, Vector pFirstDest, CGameTrace pFirstTrace)
{
	float original_velocity[3], primal_velocity[3], fixed_origin[3], valid_plane[3], new_velocity[3], end[3], dir[3];
	float allFraction, d, time_left = GetGameFrameTime(), planes[MAX_CLIP_PLANES][3];
	int bumpcount, blocked, numplanes, numbumps = gRampBumpCount.IntValue, i, j, h;
	bool stuck_on_ramp, has_valid_plane, embedded, rescue_tried;
	CGameTrace pm = CGameTrace();
	
	Vector vecVelocity = pThis.mv.m_vecVelocity;
	vecVelocity.ToArray(original_velocity);
	vecVelocity.ToArray(primal_velocity);
	Vector vecAbsOrigin = pThis.mv.m_vecAbsOrigin;
	vecAbsOrigin.ToArray(fixed_origin);
	
	Vector plane_normal;
	static Vector alloced_vector, alloced_vector2;
	
	if(alloced_vector.Address == Address_Null)
		alloced_vector = Vector();
	
	if(alloced_vector2.Address == Address_Null)
		alloced_vector2 = Vector();
	
	CBaseHandle hPlayer = pThis.mv.m_nPlayerHandle;
	int hidx = hPlayer.m_Index;
	int client = (hidx == INVALID_EHANDLE_INDEX) ? -1 : (hidx & ENT_ENTRY_MASK);
	bool track = client >= 1 && client <= MAXPLAYERS;
	if(track && gLastPlaneHandle[client] != hidx)
	{
		VectorCopy(vec3_origin, gLastPlane[client]);
		gLastPlaneHandle[client] = hidx;
	}
	bool prev_frac0 = false;


	for(bumpcount = 0; bumpcount < numbumps; bumpcount++)
	{
		if(vecVelocity.LengthSqr() == 0.0)
			break;
		
		// Stuck path: the previous bump's move trace was unusable (startsolid or
		// zero fraction). Find a plane to clip against and nudge off of, in
		// cheapest-first order: the last trace's plane, then the planes already
		// hit this tick, then a 27-trace sweep, then the embedded rescue.
		if(stuck_on_ramp)
		{
			if(!has_valid_plane)
			{
				plane_normal = pm.plane.normal;
				if(!CloseEnough(VectorToArray(plane_normal), view_as<float>({0.0, 0.0, 0.0})) &&
					!IsEqual(valid_plane, VectorToArray(plane_normal)))
				{
					plane_normal.ToArray(valid_plane);
					has_valid_plane = true;
				}
				else
				{
					for(i = numplanes; i-- > 0;)
					{
						if(!CloseEnough(planes[i], view_as<float>({0.0, 0.0, 0.0})) &&
							FloatAbs(planes[i][0]) <= 1.0 && FloatAbs(planes[i][1]) <= 1.0 && FloatAbs(planes[i][2]) <= 1.0 &&
							!IsEqual(valid_plane, planes[i]))
						{
							VectorCopy(planes[i], valid_plane);
							has_valid_plane = true;
							break;
						}
					}
				}
			}
			
			if(has_valid_plane)
			{
				// Standable plane (z >= 0.7) clips flat; steeper surf planes get
				// sv_bounce scaled by surface friction, matching engine behaviour.
				alloced_vector.FromArray(valid_plane);
				if(valid_plane[2] >= 0.7 && valid_plane[2] <= 1.0)
				{
					ClipVelocity(pThis, vecVelocity, alloced_vector, vecVelocity, 1.0);
					vecVelocity.ToArray(original_velocity);
				}
				else
				{
					ClipVelocity(pThis, vecVelocity, alloced_vector, vecVelocity, 1.0 + gBounce.FloatValue * (1.0 - pThis.player.m_surfaceFriction));
					vecVelocity.ToArray(original_velocity);
				}
				alloced_vector.ToArray(valid_plane);
			}
			// No plane known - probe for one. The vertical-velocity gate is the
			// upstream workaround for issue #1 (noclip exit jitter): a player
			// drifting at near-zero vz skips the sweep so they fall through to
			// vanilla instead of being nudged around.
			else if(!gNoclipWorkAround.BoolValue || (vecVelocity.z < -6.25 || vecVelocity.z > 0.0))
			{
				if(gSweepFast.BoolValue)
				{
					// Fast probe: session logs showed the legacy 27-trace sweep
					// succeeding ~once in 200 runs. Instead: zero-length hull-fit
					// tests classify which sides are open (last-plane dir first,
					// then the axes), then ONE swept trace from the first open
					// spot fetches the plane. ~7 point tests + 1 swept trace vs
					// 27 grown-hull swept traces, per stuck bump.
					int valid_planes = 0;
					VectorCopy(view_as<float>({0.0, 0.0, 0.0}), valid_plane);

					float probe = (float(bumpcount) * 2.0) * gRampInitialRetraceLength.FloatValue;
					if(probe < 0.5)
						probe = 0.5;

					float pdirs[7][3];
					int npdirs = 0;
					if(track && GetVectorLength(gLastPlane[client], true) > FLT_EPSILON)
					{
						VectorCopy(gLastPlane[client], pdirs[npdirs]);
						npdirs++;
					}
					pdirs[npdirs][2] = 1.0; npdirs++;
					pdirs[npdirs][2] = -1.0; npdirs++;
					pdirs[npdirs][0] = 1.0; npdirs++;
					pdirs[npdirs][0] = -1.0; npdirs++;
					pdirs[npdirs][1] = 1.0; npdirs++;
					pdirs[npdirs][1] = -1.0; npdirs++;

					float ppos[3];
					for(i = 0; i < npdirs; i++)
					{
						VectorMA(fixed_origin, probe, pdirs[i], ppos);
						alloced_vector.FromArray(ppos);
						TracePlayerBBox(pThis, alloced_vector, alloced_vector, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
						if(pm.startsolid)
							continue;
						// open side found - one swept trace back through the move
						alloced_vector2.FromArray(end);
						TracePlayerBBox(pThis, alloced_vector, alloced_vector2, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
						plane_normal = pm.plane.normal;
						if(FloatAbs(plane_normal.x) <= 1.0 && FloatAbs(plane_normal.y) <= 1.0 &&
							FloatAbs(plane_normal.z) <= 1.0 && pm.fraction > 0.0 && pm.fraction < 1.0 && !pm.startsolid)
						{
							plane_normal.ToArray(valid_plane);
							valid_planes = 1;
							break;
						}
					}

					if(valid_planes != 0 && !CloseEnough(valid_plane, view_as<float>({0.0, 0.0, 0.0})))
					{
						has_valid_plane = true;
						NormalizeVector(valid_plane, valid_plane);
						continue;
					}
				}
				else
				{
				// Legacy 27-trace sweep: retrace the move from origins offset by
				// up to +-(bump * 2 * retrace_length) on each axis, with the hull
				// grown by the offset. Kept behind momsurffix_sweep_fast 0.
				float offsets[3];
				offsets[0] = (float(bumpcount) * 2.0) * -gRampInitialRetraceLength.FloatValue;
				offsets[2] = (float(bumpcount) * 2.0) * gRampInitialRetraceLength.FloatValue;
				int valid_planes = 0;
				
				VectorCopy(view_as<float>({0.0, 0.0, 0.0}), valid_plane);
				
				float offset[3], offset_mins[3], offset_maxs[3], buff[3];
				static Ray_t ray;
				
				// Keep this variable allocated only once
				// since ray.Init should take care of removing any left garbage values
				if(ray.Address == Address_Null)
					ray = Ray_t();
				
				for(i = 0; i < 3; i++)
				{
					for(j = 0; j < 3; j++)
					{
						for(h = 0; h < 3; h++)
						{
							offset[0] = offsets[i];
							offset[1] = offsets[j];
							offset[2] = offsets[h];
							
							VectorCopy(offset, offset_mins);
							ScaleVector(offset_mins, 0.5);
							VectorCopy(offset, offset_maxs);
							ScaleVector(offset_maxs, 0.5);
							
							if(offset[0] > 0.0)
								offset_mins[0] /= 2.0;
							if(offset[1] > 0.0)
								offset_mins[1] /= 2.0;
							if(offset[2] > 0.0)
								offset_mins[2] /= 2.0;
							
							if(offset[0] < 0.0)
								offset_maxs[0] /= 2.0;
							if(offset[1] < 0.0)
								offset_maxs[1] /= 2.0;
							if(offset[2] < 0.0)
								offset_maxs[2] /= 2.0;
							
							AddVectors(fixed_origin, offset, buff);
							SubtractVectors(end, offset, offset);
							if(gEngineVersion == Engine_CSGO)
							{
								SubtractVectors(VectorToArray(GetPlayerMins(pThis)), offset_mins, offset_mins); 
								AddVectors(VectorToArray(GetPlayerMaxs(pThis)), offset_maxs, offset_maxs);
							}
							else
							{
								SubtractVectors(VectorToArray(GetPlayerMinsCSS(pThis, alloced_vector)), offset_mins, offset_mins); 
								AddVectors(VectorToArray(GetPlayerMaxsCSS(pThis, alloced_vector2)), offset_maxs, offset_maxs);
							}
							
							ray.Init(buff, offset, offset_mins, offset_maxs);
							
							UTIL_TraceRay(ray, MASK_PLAYERSOLID, pThis, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
							
							plane_normal = pm.plane.normal;

							if(FloatAbs(plane_normal.x) <= 1.0 && FloatAbs(plane_normal.y) <= 1.0 &&
								FloatAbs(plane_normal.z) <= 1.0 && pm.fraction > 0.0 && pm.fraction < 1.0 && !pm.startsolid)
							{
								valid_planes++;
								AddVectors(valid_plane, VectorToArray(plane_normal), valid_plane);
							}
						}
					}
				}
				
				if(valid_planes != 0 && !CloseEnough(valid_plane, view_as<float>({0.0, 0.0, 0.0})))
				{
					has_valid_plane = true;
					NormalizeVector(valid_plane, valid_plane);
					continue;
				}
				}
			}
			else
			
			if(has_valid_plane)
			{
				VectorMA(fixed_origin, gRampInitialRetraceLength.FloatValue, valid_plane, fixed_origin);
			}
			else
			{
				// Hull is embedded in solid (head, feet or both) - the offset sweep
				// can't see any free plane from inside a brush. Look for the nearest
				// spot the hull actually fits and resume the move from there.
				// Deliberately ignores the noclip vz gate above: a wedged player's
				// clipped velocity usually sits exactly in that (-6.25, 0] window.
				// One attempt per call: a failed search from this origin cannot
				// succeed on a later bump, and retrying would burn ~84 traces
				// per bump on players wedged beyond the 32u radius.
				if(embedded && !rescue_tried && gRescue.BoolValue)
				{
					rescue_tried = true;
					if(TryEmbeddedRescue(pThis, fixed_origin, vecVelocity))
					{
						vecAbsOrigin.FromArray(fixed_origin);
						stuck_on_ramp = false;
						has_valid_plane = false;
						embedded = false;
						continue;
					}
				}
				stuck_on_ramp = false;
				continue;
			}
		}
		
		// Trace the move for what's left of the tick. Reuse the caller's trace
		// when the destination matches - the engine already traced that.
		VectorMA(fixed_origin, time_left, VectorToArray(vecVelocity), end);

		if(pFirstDest.Address != Address_Null && IsEqual(end, VectorToArray(pFirstDest)))
		{
			pm.Free();
			pm = pFirstTrace;
		}
		else
		{
			alloced_vector2.FromArray(end);
			
			if(stuck_on_ramp && has_valid_plane)
			{
				alloced_vector.FromArray(fixed_origin);
				TracePlayerBBox(pThis, alloced_vector, alloced_vector2, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
				pm.plane.normal.FromArray(valid_plane);
			}
			else
			{
				TracePlayerBBox(pThis, vecAbsOrigin, alloced_vector2, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pm);
			}
		}
		
		// Seam-pierce tier: a plane whose normal suddenly deviates from the one
		// we were riding (compiled seam bumps, VBSP bevel cuts), or two
		// zero-fraction traces in a row, gets dodged by re-tracing the move on
		// a line offset off the old plane. Runs before the stuck machinery so
		// phantom planes never feed it.
		if(gPierce.BoolValue && track && !stuck_on_ramp && !CloseEnough(fixed_origin, end))
		{
			bool has_last = GetVectorLength(gLastPlane[client], true) > FLT_EPSILON;
			if(has_last)
			{
				bool normal_changed = GetVectorDotProduct(VectorToArray(pm.plane.normal), gLastPlane[client]) < RAMP_BUG_THRESHOLD;
				bool last_was_wall = gLastPlane[client][2] < 0.03125;
				bool double_stuck = prev_frac0 && CloseEnoughFloat(pm.fraction, 0.0);
				if((normal_changed && !last_was_wall) || double_stuck)
					TryPierce(pThis, fixed_origin, end, gLastPlane[client], pm);
			}
			if(pm.plane.normal.Length() > 0.99)
				pm.plane.normal.ToArray(gLastPlane[client]);
			prev_frac0 = CloseEnoughFloat(pm.fraction, 0.0);
		}

		// allsolid also triggers the stuck path while grounded: enclosed spots can
		// wedge the head into a brush above while the feet still count as on-ground
		if(bumpcount > 0 && (pThis.player.m_hGroundEntity == view_as<Address>(-1) || pm.allsolid) && !IsValidMovementTrace(pThis, pm))
		{
			embedded = pm.startsolid || pm.allsolid;
			has_valid_plane = false;
			stuck_on_ramp = true;
			continue;
		}
		
		if(pm.fraction > 0.0)
		{
			// A "clean" full-length move can still end with the hull overlapping
			// solid (precision loss along steep planes). Verify the endpoint
			// actually fits before accepting it.
			if((bumpcount == 0 || pThis.player.m_hGroundEntity != view_as<Address>(-1)) && numbumps > 0 && pm.fraction == 1.0)
			{
				CGameTrace stuck = CGameTrace();
				TracePlayerBBox(pThis, pm.endpos, pm.endpos, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, stuck);
				
				if((stuck.startsolid || stuck.fraction != 1.0) && bumpcount == 0)
				{
					has_valid_plane = false;
					stuck_on_ramp = true;

					stuck.Free();
					continue;
				}
				else if(stuck.startsolid || stuck.fraction != 1.0)
				{
					vecVelocity.FromArray(vec3_origin);

					stuck.Free();
					break;
				}
				
				stuck.Free();
			}
			
			has_valid_plane = false;
			stuck_on_ramp = false;
			
			vecVelocity.ToArray(original_velocity);
			vecAbsOrigin.FromArray(VectorToArray(pm.endpos));
			vecAbsOrigin.ToArray(fixed_origin);
			allFraction += pm.fraction;
			numplanes = 0;
		}
		
		if(CloseEnoughFloat(pm.fraction, 1.0))
			break;
		
		MoveHelper().AddToTouched(pm, vecVelocity);
		
		if(pm.plane.normal.z >= 0.7)
			blocked |= 1;
		
		if(CloseEnoughFloat(pm.plane.normal.z, 0.0))
			blocked |= 2;
		
		time_left -= time_left * pm.fraction;
		
		if(numplanes >= MAX_CLIP_PLANES)
		{
			vecVelocity.FromArray(vec3_origin);
			break;
		}
		
		pm.plane.normal.ToArray(planes[numplanes]);
		numplanes++;
		
		// Standard Source clip-plane resolution from here down: walking against
		// one plane clips directly; multiple planes try each in turn, then the
		// two-plane crease slides along the planes' cross product.
		if(numplanes == 1 && pThis.player.m_MoveType == MOVETYPE_WALK && pThis.player.m_hGroundEntity != view_as<Address>(-1))
		{
			Vector vec1 = Vector();
			if(planes[0][2] >= 0.7)
			{
				vec1.FromArray(original_velocity);
				alloced_vector2.FromArray(planes[0]);
				alloced_vector.FromArray(new_velocity);
				ClipVelocity(pThis, vec1, alloced_vector2, alloced_vector, 1.0);
				alloced_vector.ToArray(original_velocity);
				alloced_vector.ToArray(new_velocity);
			}
			else
			{
				vec1.FromArray(original_velocity);
				alloced_vector2.FromArray(planes[0]);
				alloced_vector.FromArray(new_velocity);
				ClipVelocity(pThis, vec1, alloced_vector2, alloced_vector, 1.0 + gBounce.FloatValue * (1.0 - pThis.player.m_surfaceFriction));
				alloced_vector.ToArray(new_velocity);
			}
			
			vecVelocity.FromArray(new_velocity);
			VectorCopy(new_velocity, original_velocity);
			
			vec1.Free();
		}
		else
		{
			for(i = 0; i < numplanes; i++)
			{
				alloced_vector2.FromArray(original_velocity);
				alloced_vector.FromArray(planes[i]);
				ClipVelocity(pThis, alloced_vector2, alloced_vector, vecVelocity, 1.0);
				alloced_vector.ToArray(planes[i]);
				
				for(j = 0; j < numplanes; j++)
					if(j != i)
						if(vecVelocity.Dot(planes[j]) < 0.0)
							break;
				
				if(j == numplanes)
					break;
			}
			
			if(i != numplanes)
			{
				// found a plane whose clip keeps us off every other plane
			}
			else
			{
				if(numplanes != 2)
				{
					vecVelocity.FromArray(vec3_origin);
					break;
				}
				
				if(CloseEnough(planes[0], planes[1]))
				{
					VectorMA(original_velocity, 20.0, planes[0], new_velocity);
					vecVelocity.x = new_velocity[0];
					vecVelocity.y = new_velocity[1];
					
					break;
				}
				
				GetVectorCrossProduct(planes[0], planes[1], dir);
				NormalizeVector(dir, dir);
				
				d = vecVelocity.Dot(dir);
				
				ScaleVector(dir, d);
				vecVelocity.FromArray(dir);
			}
			
			d = vecVelocity.Dot(primal_velocity);
			if(d <= 0.0)
			{
				vecVelocity.FromArray(vec3_origin);
				break;
			}
		}
	}
	
	if(CloseEnoughFloat(allFraction, 0.0))
	{
		vecVelocity.FromArray(vec3_origin);
	}
	
	pm.Free();
	return blocked;
}

stock void VectorMA(float start[3], float scale, float dir[3], float dest[3])
{
	dest[0] = start[0] + dir[0] * scale;
	dest[1] = start[1] + dir[1] * scale;
	dest[2] = start[2] + dir[2] * scale;
}

stock void VectorCopy(float from[3], float to[3])
{
	to[0] = from[0];
	to[1] = from[1];
	to[2] = from[2];
}

stock float[] VectorToArray(Vector vec)
{
	float ret[3];
	vec.ToArray(ret);
	return ret;
}

stock bool IsEqual(float a[3], float b[3])
{
	return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

stock bool CloseEnough(float a[3], float b[3], float eps = FLT_EPSILON)
{
	return FloatAbs(a[0] - b[0]) <= eps &&
		FloatAbs(a[1] - b[1]) <= eps &&
		FloatAbs(a[2] - b[2]) <= eps;
}

stock bool CloseEnoughFloat(float a, float b, float eps = FLT_EPSILON)
{
	return FloatAbs(a - b) <= eps;
}

public void SetFailStateCustom(const char[] fmt, any ...)
{
	char buff[512];
	VFormat(buff, sizeof(buff), fmt, 2);
	
	CleanUpUtils();
	
	char ostype[32];
	switch(gOSType)
	{
		case OSLinux:	ostype = "LIN";
		case OSWindows:	ostype = "WIN";
		default:		ostype = "UNK";
	}
	
	SetFailState("[%s | %i] %s", ostype, gEngineVersion, buff);
}

// Seam-pierce (SurfSam's port of the CS2-gist approach, primary-direction
// first): re-trace the move on a line offset RAMP_PIERCE_DISTANCE off the
// last plane the player validly rode. If the offset trace runs clean, keeps
// riding the same plane, or lands on a coherent new one, adopt it as the
// movement result - the phantom seam plane is never resolved against.
// Typical cost 2-3 traces; worst case ~28 when every candidate fails.
bool TryPierce(CGameMovement pThis, float start[3], float end[3], float lastPlane[3], CGameTrace pm)
{
	float errN[3], dir[3], offStart[3], offEnd[3], buff[3];
	pm.plane.normal.ToArray(errN);

	static Vector vs, ve;
	static CGameTrace pierce, confirm;
	if(vs.Address == Address_Null) vs = Vector();
	if(ve.Address == Address_Null) ve = Vector();
	if(pierce.Address == Address_Null) pierce = CGameTrace();
	if(confirm.Address == Address_Null) confirm = CGameTrace();

	float total = GetVectorDistance(start, end);
	static const float offsets[] = {0.0, -1.0, 1.0};

	// candidate 0 is the last plane's own normal, tried at two depths; the
	// axis fan (filtered to directions off the plane) is the rare fallback
	for(int cand = 0; cand < 27; cand++)
	{
		int nratios;
		if(cand == 0)
		{
			VectorCopy(lastPlane, dir);
			nratios = 2;
		}
		else
		{
			dir[0] = offsets[cand / 9];
			dir[1] = offsets[(cand / 3) % 3];
			dir[2] = offsets[cand % 3];
			if(GetVectorDotProduct(lastPlane, dir) <= 0.0)
				continue;
			nratios = 1;
		}

		for(int r = 0; r < nratios; r++)
		{
			float depth = RAMP_PIERCE_DISTANCE * ((cand == 0 && nratios == 2 && r == 0) ? 0.5 : 1.0);
			VectorMA(start, depth, dir, offStart);
			VectorMA(end, depth, dir, offEnd);
			vs.FromArray(offStart);
			ve.FromArray(offEnd);
			TracePlayerBBox(pThis, vs, ve, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, pierce);
			if(!IsValidMovementTrace(pThis, pierce))
				continue;

			float pierceN[3];
			pierce.plane.normal.ToArray(pierceN);
			bool valid_plane = pierce.fraction < 1.0 && pierce.fraction > 0.1
				&& GetVectorDotProduct(pierceN, lastPlane) >= RAMP_BUG_THRESHOLD;
			bool hit_new = GetVectorDotProduct(errN, pierceN) < NEW_RAMP_THRESHOLD
				&& GetVectorDotProduct(lastPlane, pierceN) > NEW_RAMP_THRESHOLD;
			bool good = CloseEnoughFloat(pierce.fraction, 1.0) || valid_plane;
			if(!good && !hit_new)
				continue;

			// land back on the intended line before adopting
			pierce.endpos.ToArray(buff);
			vs.FromArray(buff);
			ve.FromArray(end);
			TracePlayerBBox(pThis, vs, ve, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, confirm);
			if(!IsValidMovementTrace(pThis, confirm))
				continue;

			pierce.CopyTo(pm);
			pm.startpos.FromArray(start);
			confirm.endpos.ToArray(buff);
			pm.endpos.FromArray(buff);
			pierce.endpos.ToArray(buff);
			float frac = total > 0.0 ? GetVectorDistance(offStart, buff) / total : 1.0;
			pm.fraction = frac < 1.0 ? frac : 1.0;
			if(pm.plane.normal.Length() <= FLT_EPSILON)
				confirm.plane.normal.ToArray(buff), pm.plane.normal.FromArray(buff);
			return true;
		}
	}
	return false;
}

// Expanding-shell search for the nearest origin where the player hull fits.
// Zero-length hull tests only (<= 12 shells x 7 dirs = 84 traces), and only
// runs when the player is already embedded in solid - the case where every
// other path has failed and the player would otherwise stay frozen forever.
// The 32u radius cap is deliberate: big enough for any wedge, too small to
// cross a wall. ponytail: fixed shell table, no BSP-aware push-out.
bool TryEmbeddedRescue(CGameMovement pThis, float org[3], Vector vecVelocity)
{
	// dense up to hull height - wedge pockets are often barely hull-sized
	static const float shells[] = {1.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 20.0, 24.0, 32.0};
	float dirs[7][3];
	int ndirs = 0;

	// back out the way we came in first
	float v[3];
	vecVelocity.ToArray(v);
	if(GetVectorLength(v, true) > 1.0)
	{
		NormalizeVector(v, v);
		ScaleVector(v, -1.0);
		VectorCopy(v, dirs[ndirs++]);
	}
	dirs[ndirs][2] = 1.0; ndirs++;
	dirs[ndirs][2] = -1.0; ndirs++;
	dirs[ndirs][0] = 1.0; ndirs++;
	dirs[ndirs][0] = -1.0; ndirs++;
	dirs[ndirs][1] = 1.0; ndirs++;
	dirs[ndirs][1] = -1.0; ndirs++;

	static Vector cand;
	if(cand.Address == Address_Null)
		cand = Vector();

	static CGameTrace tr;
	if(tr.Address == Address_Null)
		tr = CGameTrace();

	float pos[3];
	bool found = false;

	for(int s = 0; s < sizeof(shells) && !found; s++)
	{
		for(int d = 0; d < ndirs && !found; d++)
		{
			VectorMA(org, shells[s], dirs[d], pos);
			cand.FromArray(pos);
			TracePlayerBBox(pThis, cand, cand, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, tr);
			if(!tr.startsolid && CloseEnoughFloat(tr.fraction, 1.0))
			{
				VectorCopy(pos, org);
				found = true;
			}
		}
	}

	return found;
}

stock bool IsValidMovementTrace(CGameMovement pThis, CGameTrace tr)
{
	if(tr.allsolid || tr.startsolid)
		return false;
	
	if(CloseEnoughFloat(tr.fraction, 0.0))
		return false;
	
	Vector plane_normal = tr.plane.normal;
	if(FloatAbs(plane_normal.x) > 1.0 || FloatAbs(plane_normal.y) > 1.0 || FloatAbs(plane_normal.z) > 1.0)
		return false;
	
	CGameTrace stuck = CGameTrace();
	
	TracePlayerBBox(pThis, tr.endpos, tr.endpos, MASK_PLAYERSOLID, COLLISION_GROUP_PLAYER_MOVEMENT, stuck);
	if(stuck.startsolid || !CloseEnoughFloat(stuck.fraction, 1.0))
	{
		stuck.Free();
		return false;
	}
	
	stuck.Free();
	return true;
}

stock void UTIL_TraceRay(Ray_t ray, int mask, CGameMovement gm, int collisionGroup, CGameTrace trace)
{
	if(gEngineVersion == Engine_CSGO)
	{
		CTraceFilterSimple filter = LockTraceFilter(gm, collisionGroup);
		
		gm.m_nTraceCount++;
		ITraceListData tracelist = gm.m_pTraceListData;
		
		if(tracelist.Address != Address_Null && tracelist.CanTraceRay(ray))
			TraceRayAgainstLeafAndEntityList(ray, tracelist, mask, filter, trace);
		else
			TraceRay(ray, mask, filter, trace);
		
		UnlockTraceFilter(gm, filter);
	}
	else if(gEngineVersion == Engine_CSS)
	{
		CTraceFilterSimple filter = CTraceFilterSimple();
		filter.Init(LookupEntity(gm.mv.m_nPlayerHandle), collisionGroup);
		
		TraceRay(ray, mask, filter, trace);
		
		filter.Free();
	}
}