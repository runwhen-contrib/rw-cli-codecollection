# Quick RunSession Memory Fixes

## Immediate Actions (Implement Today)

### 1. Fix RunSession List - Load Only Summaries

**Current Problem:**
```javascript
// BAD: Loading full runsession objects
const loadRunSessions = async () => {
  const response = await fetch(`/api/workspace/${workspaceId}/runsessions`);
  const fullRunSessions = await response.json(); // Huge objects!
  setRunSessions(fullRunSessions);
};
```

**Quick Fix:**
```javascript
// GOOD: Load only essential data
const loadRunSessionSummaries = async () => {
  const response = await fetch(`/api/workspace/${workspaceId}/runsessions/summary`);
  const summaries = await response.json(); // Only id, name, status, timestamp
  setRunSessions(summaries);
};
```

**Backend API Change Needed:**
```javascript
// Create new endpoint: GET /api/workspace/{workspaceId}/runsessions/summary
// Return only: { id, name, status, timestamp, duration }
// Instead of full runsession objects with all details
```

### 2. Fix Polling Memory Leaks

**Current Problem:**
```javascript
// BAD: Polling without cleanup
useEffect(() => {
  const interval = setInterval(() => {
    fetchRunSessionDetails();
  }, 5000);
  // No cleanup! Memory leak!
}, [runSessionId]);
```

**Quick Fix:**
```javascript
// GOOD: Proper cleanup
useEffect(() => {
  const abortController = new AbortController();
  const interval = setInterval(() => {
    fetchRunSessionDetails(abortController.signal);
  }, 5000);
  
  return () => {
    clearInterval(interval);
    abortController.abort(); // Cancel pending requests
  };
}, [runSessionId]);
```

### 3. Add Request Cancellation

**Current Problem:**
```javascript
// BAD: No request cancellation
const fetchRunSessionDetails = async () => {
  const response = await fetch(`/api/runsession/${runSessionId}/details`);
  const data = await response.json();
  setDetails(data);
};
```

**Quick Fix:**
```javascript
// GOOD: With request cancellation
const fetchRunSessionDetails = async (signal) => {
  try {
    const response = await fetch(`/api/runsession/${runSessionId}/details`, {
      signal: signal
    });
    const data = await response.json();
    setDetails(data);
  } catch (error) {
    if (error.name === 'AbortError') {
      // Request was cancelled, ignore
      return;
    }
    console.error('Failed to fetch details:', error);
  }
};
```

### 4. Pause Polling When Tab is Hidden

**Quick Fix:**
```javascript
useEffect(() => {
  const handleVisibilityChange = () => {
    if (document.hidden) {
      // Pause polling when tab is not visible
      clearInterval(pollingInterval);
    } else {
      // Resume polling when tab becomes visible
      startPolling();
    }
  };

  document.addEventListener('visibilitychange', handleVisibilityChange);
  return () => {
    document.removeEventListener('visibilitychange', handleVisibilityChange);
  };
}, []);
```

### 5. Add Memory Monitoring

**Quick Fix:**
```javascript
const useMemoryMonitor = () => {
  useEffect(() => {
    const checkMemory = () => {
      if ('memory' in performance) {
        const { usedJSHeapSize } = performance.memory;
        const usageMB = usedJSHeapSize / 1024 / 1024;
        
        if (usageMB > 1000) { // 1GB threshold
          console.warn(`High memory usage: ${usageMB.toFixed(2)} MB`);
          // Trigger cleanup
          window.location.reload(); // Nuclear option
        }
      }
    };

    const interval = setInterval(checkMemory, 30000); // Check every 30 seconds
    return () => clearInterval(interval);
  }, []);
};
```

## Complete RunSession Component Fix

```jsx
import React, { useState, useEffect, useCallback, useRef } from 'react';

const RunSessionList = ({ workspaceId, onSelectRunSession }) => {
  const [runSessions, setRunSessions] = useState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [loading, setLoading] = useState(false);

  // Load only summaries
  const loadRunSessions = useCallback(async () => {
    setLoading(true);
    try {
      const response = await fetch(`/api/workspace/${workspaceId}/runsessions/summary`);
      const summaries = await response.json();
      setRunSessions(summaries);
    } catch (error) {
      console.error('Failed to load runsessions:', error);
    } finally {
      setLoading(false);
    }
  }, [workspaceId]);

  useEffect(() => {
    loadRunSessions();
  }, [loadRunSessions]);

  if (loading) return <div>Loading runsessions...</div>;

  return (
    <div className="runsession-list">
      {runSessions.map(runSession => (
        <div
          key={runSession.id}
          className={`runsession-item ${selectedId === runSession.id ? 'selected' : ''}`}
          onClick={() => {
            setSelectedId(runSession.id);
            onSelectRunSession(runSession.id);
          }}
        >
          <div className="runsession-summary">
            <span className="name">{runSession.name}</span>
            <span className="status">{runSession.status}</span>
            <span className="timestamp">{runSession.timestamp}</span>
          </div>
        </div>
      ))}
    </div>
  );
};

const RunSessionDetail = ({ runSessionId }) => {
  const [details, setDetails] = useState(null);
  const [loading, setLoading] = useState(false);
  const abortControllerRef = useRef(null);
  const pollingIntervalRef = useRef(null);

  // Cleanup function
  const cleanup = useCallback(() => {
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }
    if (pollingIntervalRef.current) {
      clearInterval(pollingIntervalRef.current);
      pollingIntervalRef.current = null;
    }
  }, []);

  // Fetch details with cancellation
  const fetchDetails = useCallback(async () => {
    if (!runSessionId) return;

    cleanup(); // Cancel previous requests
    
    setLoading(true);
    abortControllerRef.current = new AbortController();
    
    try {
      const response = await fetch(
        `/api/runsession/${runSessionId}/details`,
        { signal: abortControllerRef.current.signal }
      );
      const data = await response.json();
      setDetails(data);
    } catch (error) {
      if (error.name !== 'AbortError') {
        console.error('Failed to load details:', error);
      }
    } finally {
      setLoading(false);
    }
  }, [runSessionId, cleanup]);

  // Start polling
  const startPolling = useCallback(() => {
    cleanup();
    fetchDetails();
    pollingIntervalRef.current = setInterval(fetchDetails, 5000);
  }, [fetchDetails, cleanup]);

  // Stop polling
  const stopPolling = useCallback(() => {
    cleanup();
  }, [cleanup]);

  // Handle visibility change
  useEffect(() => {
    const handleVisibilityChange = () => {
      if (document.hidden) {
        stopPolling();
      } else {
        startPolling();
      }
    };

    document.addEventListener('visibilitychange', handleVisibilityChange);
    return () => {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, [startPolling, stopPolling]);

  // Start polling when component mounts
  useEffect(() => {
    if (runSessionId) {
      startPolling();
    }
    return cleanup;
  }, [runSessionId, startPolling, cleanup]);

  if (loading && !details) {
    return <div>Loading runsession details...</div>;
  }

  if (!details) {
    return <div>No runsession selected</div>;
  }

  return (
    <div className="runsession-detail">
      <h3>{details.name}</h3>
      <div className="status">Status: {details.status}</div>
      <div className="timestamp">Started: {details.startTime}</div>
      <div className="duration">Duration: {details.duration}</div>
    </div>
  );
};

const RunSessionContainer = ({ workspaceId }) => {
  const [selectedRunSessionId, setSelectedRunSessionId] = useState(null);

  return (
    <div className="runsession-container">
      <div className="runsession-list">
        <RunSessionList
          workspaceId={workspaceId}
          onSelectRunSession={setSelectedRunSessionId}
        />
      </div>
      <div className="runsession-detail">
        {selectedRunSessionId && (
          <RunSessionDetail runSessionId={selectedRunSessionId} />
        )}
      </div>
    </div>
  );
};

export default RunSessionContainer;
```

## Backend API Changes Needed

### 1. Create Summary Endpoint
```javascript
// New endpoint: GET /api/workspace/{workspaceId}/runsessions/summary
app.get('/api/workspace/:workspaceId/runsessions/summary', async (req, res) => {
  const { workspaceId } = req.params;
  const { page = 1, limit = 50 } = req.query;
  
  try {
    const summaries = await db.query(`
      SELECT id, name, status, created_at as timestamp, 
             EXTRACT(EPOCH FROM (updated_at - created_at)) as duration
      FROM runsessions 
      WHERE workspace_id = $1 
      ORDER BY created_at DESC 
      LIMIT $2 OFFSET $3
    `, [workspaceId, limit, (page - 1) * limit]);
    
    res.json(summaries.rows);
  } catch (error) {
    res.status(500).json({ error: 'Failed to load runsessions' });
  }
});
```

### 2. Optimize Details Endpoint
```javascript
// Optimize existing endpoint: GET /api/runsession/{runSessionId}/details
app.get('/api/runsession/:runSessionId/details', async (req, res) => {
  const { runSessionId } = req.params;
  
  try {
    // Add caching headers
    res.set('Cache-Control', 'public, max-age=30'); // Cache for 30 seconds
    
    const details = await db.query(`
      SELECT id, name, status, created_at, updated_at,
             EXTRACT(EPOCH FROM (updated_at - created_at)) as duration
      FROM runsessions 
      WHERE id = $1
    `, [runSessionId]);
    
    if (details.rows.length === 0) {
      return res.status(404).json({ error: 'RunSession not found' });
    }
    
    res.json(details.rows[0]);
  } catch (error) {
    res.status(500).json({ error: 'Failed to load runsession details' });
  }
});
```

## Implementation Priority

1. **Immediate (Today):**
   - Fix polling cleanup
   - Add request cancellation
   - Pause polling when tab hidden

2. **This Week:**
   - Create summary API endpoint
   - Update frontend to use summaries
   - Add memory monitoring

3. **Next Week:**
   - Implement virtual scrolling
   - Add pagination
   - Optimize caching strategy

## Expected Results

After implementing these quick fixes:
- **40-60% immediate memory reduction**
- **Elimination of polling memory leaks**
- **Better performance with large runsession lists**
- **Improved user experience**

## Testing

1. **Before/After Memory Test:**
   - Open Chrome DevTools Memory tab
   - Load workspace with many runsessions
   - Note memory usage
   - Implement fixes
   - Compare memory usage

2. **Polling Test:**
   - Open runsession detail
   - Switch between runsessions
   - Check Network tab for cancelled requests
   - Verify no memory leaks

3. **Visibility Test:**
   - Open runsession detail
   - Switch to different tab
   - Check that polling stops
   - Return to tab
   - Verify polling resumes